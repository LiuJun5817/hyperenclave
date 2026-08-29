// Copyright (C) 2023 Ant Group CO., Ltd. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use alloc::{vec, vec::Vec};
use core::{cmp::Ordering, marker::PhantomData};

use libvmm::msr::Msr;
use libvmm::vmx::flags::{EptpFlags, InvEptType, VmxEptVpidCap};
use verified_hv_mem::{
    address::{
        addr::{PAddr, VAddr},
        frame::{Frame as VerifiedFrame, FrameSize, MemAttr},
    },
    bitmap_allocator::bitmap_impl::BitAlloc1M,
    page_table::{
        pt_arch::{PTArch, PTArchLevel},
        ExPageTable, PTConstants, PageTable as VerifiedPageTable, X86PTE,
    },
};

use crate::error::HvResult;
use crate::memory::addr::{phys_virt_offset, GuestPhysAddr, HostPhysAddr};
use crate::memory::{
    gb_allocator, GenericPageTable, GenericPageTableImmut, MemFlags, MemoryRegion, PageSize,
    PagingError, PagingInstr, PagingResult,
};

const ENTRY_COUNT: usize = 512;

/// Intel's verified EPT entry implementation.
pub use verified_hv_mem::page_table::X86PTE as EPTEntry;

pub struct EPTInstr;

impl EPTInstr {
    pub fn set_ept_pointer(pml4_paddr: usize) -> HvResult {
        let mut eptp_flags = EptpFlags::empty();
        // TODO: support 5-level page tables
        if (*VMX_EPT_VIPD_CAP).contains(VmxEptVpidCap::WALK_LENGTH_4) {
            eptp_flags |= EptpFlags::WALK_LENGTH_4;
        }
        if (*VMX_EPT_VIPD_CAP).contains(VmxEptVpidCap::MEMORY_TYPE_WB) {
            eptp_flags |= EptpFlags::MEMORY_TYPE_WB;
        }

        // Keep EPT A/D disabled. The verified page-table model owns the entry
        // memory exclusively, so hardware must not mutate entries behind it.
        let invept_type = if (*VMX_EPT_VIPD_CAP).contains(VmxEptVpidCap::INVEPT_TYPE_SINGLE_CONTEXT)
        {
            InvEptType::SingleContext
        } else {
            InvEptType::Global
        };
        libvmm::vmx::Vmcs::set_ept_pointer(pml4_paddr, eptp_flags, invept_type)?;
        Ok(())
    }
}

impl PagingInstr for EPTInstr {
    unsafe fn activate(root_paddr: HostPhysAddr) {
        EPTInstr::set_ept_pointer(root_paddr).expect("Failed to set EPT_POINTER");
    }

    fn flush(_vaddr: Option<usize>) {
        // EPT invalidation is performed when the EPT pointer is installed.
    }
}

lazy_static! {
    pub static ref VMX_EPT_VIPD_CAP: VmxEptVpidCap =
        VmxEptVpidCap::from_bits_truncate(Msr::IA32_VMX_EPT_VPID_CAP.read());
}

/// A four-level Intel EPT backed by the verified page-table implementation.
pub struct VerifiedEpt<I: PagingInstr> {
    inner: ExPageTable<BitAlloc1M, X86PTE>,
    _phantom: PhantomData<I>,
}

impl<I: PagingInstr> VerifiedEpt<I> {
    fn query_mapping(&self, gpaddr: GuestPhysAddr) -> PagingResult<(VAddr, VerifiedFrame)> {
        self.inner
            .query(VAddr(gpaddr))
            .map_err(|_| PagingError::NotMapped(gpaddr))
    }
}

impl<I: PagingInstr> GenericPageTableImmut for VerifiedEpt<I> {
    type VA = GuestPhysAddr;

    unsafe fn from_root(_root_paddr: HostPhysAddr) -> Self {
        unimplemented!("verified-hv-mem cannot take ownership of an existing EPT root")
    }

    fn root_paddr(&self) -> HostPhysAddr {
        self.inner.root().0
    }

    fn query(&self, gpaddr: GuestPhysAddr) -> PagingResult<(HostPhysAddr, MemFlags, PageSize)> {
        let (vbase, frame) = self.query_mapping(gpaddr)?;
        let page_size = frame_size_to_page_size(frame.size)?;
        let paddr = frame.base.0 + (gpaddr - vbase.0);
        let flags = attr_to_flags(frame.attr);
        if flags.contains(MemFlags::NO_PRESENT) {
            Err(PagingError::NotPresent((gpaddr, paddr, flags, page_size)))
        } else {
            Ok((paddr, flags, page_size))
        }
    }
}

impl<I: PagingInstr> GenericPageTable for VerifiedEpt<I> {
    fn new() -> Self {
        Self {
            inner: ExPageTable::<BitAlloc1M, X86PTE>::new(gb_allocator(), intel_ept_constants()),
            _phantom: PhantomData,
        }
    }

    fn map(&mut self, region: &MemoryRegion<Self::VA>) -> PagingResult {
        let attr = flags_to_attr(region.flags)?;
        let mut gpaddr = region.start;
        let mut size = region.size;

        while size > 0 {
            let hpaddr = region.mapped_paddr(gpaddr);
            let page_size = select_page_size(gpaddr, hpaddr, size, region.flags);
            let frame = VerifiedFrame {
                base: PAddr(hpaddr),
                size: page_size_to_frame_size(page_size),
                attr,
            };

            self.inner
                .map(gb_allocator(), VAddr(gpaddr), frame)
                .map_err(|_| {
                    PagingError::AlreadyMapped((gpaddr, hpaddr, region.flags, page_size))
                })?;

            gpaddr += page_size as usize;
            size -= page_size as usize;
        }
        Ok(())
    }

    fn unmap(
        &mut self,
        region: &MemoryRegion<Self::VA>,
    ) -> PagingResult<Vec<(HostPhysAddr, PageSize)>> {
        let mut unmapped = Vec::new();
        let mut gpaddr = region.start;
        let mut size = region.size;

        while size > 0 {
            let (vbase, frame) = self.query_mapping(gpaddr)?;
            let page_size = frame_size_to_page_size(frame.size)?;
            let flags = attr_to_flags(frame.attr);
            if vbase.0 != gpaddr || page_size as usize > size {
                return Err(PagingError::MappedToHugePage((
                    gpaddr,
                    frame.base.0,
                    flags,
                    page_size,
                )));
            }

            let removed = self
                .inner
                .unmap(gb_allocator(), vbase)
                .map_err(|_| PagingError::NotMapped(gpaddr))?;
            unmapped.push((removed.base.0, page_size));
            gpaddr += page_size as usize;
            size -= page_size as usize;
        }
        Ok(unmapped)
    }

    fn update(&mut self, region: &MemoryRegion<Self::VA>) -> PagingResult {
        let gpaddr = region.start;
        let (vbase, old_frame) = self.query_mapping(gpaddr)?;
        let page_size = frame_size_to_page_size(old_frame.size)?;
        let old_flags = attr_to_flags(old_frame.attr);

        match (page_size as usize).cmp(&region.size) {
            Ordering::Greater => {
                return Err(PagingError::MappedToHugePage((
                    gpaddr,
                    old_frame.base.0,
                    old_flags,
                    page_size,
                )))
            }
            Ordering::Less => {
                return Err(PagingError::AlreadyMapped((
                    gpaddr,
                    old_frame.base.0,
                    old_flags,
                    page_size,
                )))
            }
            Ordering::Equal => {}
        }
        if vbase.0 != gpaddr {
            return Err(PagingError::MappedToHugePage((
                gpaddr,
                old_frame.base.0,
                old_flags,
                page_size,
            )));
        }

        let new_frame = VerifiedFrame {
            base: PAddr(page_size.align_down(region.mapped_paddr(gpaddr))),
            size: old_frame.size,
            attr: flags_to_attr(region.flags)?,
        };
        let rollback_frame = VerifiedFrame {
            base: old_frame.base,
            size: old_frame.size,
            attr: old_frame.attr,
        };

        self.inner
            .unmap(gb_allocator(), vbase)
            .map_err(|_| PagingError::NotMapped(gpaddr))?;
        if self.inner.map(gb_allocator(), vbase, new_frame).is_err() {
            let rollback = self.inner.map(gb_allocator(), vbase, rollback_frame);
            debug_assert!(rollback.is_ok(), "failed to roll back an EPT update");
            return Err(PagingError::NoMemory);
        }
        Ok(())
    }

    fn clone(&self) -> Self {
        unimplemented!("verified-hv-mem does not support cloning an owned EPT")
    }

    unsafe fn activate(&self) {
        I::activate(self.root_paddr())
    }

    fn flush(&self, gpaddr: Option<Self::VA>) {
        I::flush(gpaddr)
    }
}

pub type ExtendedPageTable = VerifiedEpt<EPTInstr>;
pub type EnclaveExtendedPageTableUnlocked = VerifiedEpt<EPTInstr>;

fn intel_ept_constants() -> PTConstants {
    PTConstants {
        arch: PTArch(vec![
            PTArchLevel {
                entry_count: ENTRY_COUNT,
                frame_size: FrameSize::Size512G,
            },
            PTArchLevel {
                entry_count: ENTRY_COUNT,
                frame_size: FrameSize::Size1G,
            },
            PTArchLevel {
                entry_count: ENTRY_COUNT,
                frame_size: FrameSize::Size2M,
            },
            PTArchLevel {
                entry_count: ENTRY_COUNT,
                frame_size: FrameSize::Size4K,
            },
        ]),
        huge_pages: true,
        hva_to_pa_offset: phys_virt_offset(),
    }
}

fn flags_to_attr(flags: MemFlags) -> PagingResult<MemAttr> {
    let has_permissions = flags.intersects(MemFlags::READ | MemFlags::WRITE | MemFlags::EXECUTE);
    if flags.contains(MemFlags::NO_PRESENT) && has_permissions {
        error!("a non-present EPT mapping cannot carry R/W/X permissions");
        return Err(PagingError::UnexpectedError);
    }

    let non_present = flags.contains(MemFlags::NO_PRESENT);
    Ok(MemAttr {
        readable: !non_present && flags.contains(MemFlags::READ),
        writable: !non_present && flags.contains(MemFlags::WRITE),
        executable: !non_present && flags.contains(MemFlags::EXECUTE),
        device: flags.contains(MemFlags::IO),
    })
}

fn attr_to_flags(attr: MemAttr) -> MemFlags {
    let mut flags = MemFlags::empty();
    if attr.readable {
        flags |= MemFlags::READ;
    }
    if attr.writable {
        flags |= MemFlags::WRITE;
    }
    if attr.executable {
        flags |= MemFlags::EXECUTE;
    }
    if attr.device {
        flags |= MemFlags::IO;
    }
    if !attr.readable && !attr.writable && !attr.executable {
        flags |= MemFlags::NO_PRESENT;
    }
    flags
}

fn select_page_size(
    gpaddr: GuestPhysAddr,
    hpaddr: HostPhysAddr,
    remaining: usize,
    flags: MemFlags,
) -> PageSize {
    if PageSize::Size1G.is_aligned(gpaddr)
        && PageSize::Size1G.is_aligned(hpaddr)
        && remaining >= PageSize::Size1G as usize
        && !flags.contains(MemFlags::NO_HUGEPAGES)
    {
        PageSize::Size1G
    } else if PageSize::Size2M.is_aligned(gpaddr)
        && PageSize::Size2M.is_aligned(hpaddr)
        && remaining >= PageSize::Size2M as usize
        && !flags.contains(MemFlags::NO_HUGEPAGES)
    {
        PageSize::Size2M
    } else {
        PageSize::Size4K
    }
}

fn page_size_to_frame_size(size: PageSize) -> FrameSize {
    match size {
        PageSize::Size4K => FrameSize::Size4K,
        PageSize::Size2M => FrameSize::Size2M,
        PageSize::Size1G => FrameSize::Size1G,
    }
}

fn frame_size_to_page_size(size: FrameSize) -> PagingResult<PageSize> {
    match size {
        FrameSize::Size4K => Ok(PageSize::Size4K),
        FrameSize::Size2M => Ok(PageSize::Size2M),
        FrameSize::Size1G => Ok(PageSize::Size1G),
        _ => Err(PagingError::UnexpectedError),
    }
}
