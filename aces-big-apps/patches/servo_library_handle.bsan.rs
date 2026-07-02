/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// BSAN-safe FreeType allocator hooks for Servo (aces patch).
//
// Upstream probes jemalloc chunk metadata in FreeType hooks and MallocSizeOf (BSAN OOB).
//
// This patch:
// - Tracks requested sizes per pointer (FreeType's free callback has no size argument).
// - Avoids ops.malloc_size_of() on FT_Library / FT_Memory opaque pointers.

use std::collections::HashMap;
use std::os::raw::{c_long, c_void};
use std::ptr;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use freetype_sys::{
    FT_Add_Default_Modules, FT_Done_Library, FT_Library, FT_Memory, FT_MemoryRec, FT_New_Library,
};
use malloc_size_of::{MallocSizeOf, MallocSizeOfOps};
use parking_lot::{Mutex, ReentrantMutex};
use servo_allocator::libc_compat::{free, malloc, realloc};

static FREETYPE_MEMORY_USAGE: AtomicUsize = AtomicUsize::new(0);
static FREETYPE_ALLOC_SIZES: OnceLock<Mutex<HashMap<usize, usize>>> = OnceLock::new();
static FREETYPE_LIBRARY_HANDLE: OnceLock<ReentrantMutex<FreeTypeLibraryHandle>> = OnceLock::new();

fn alloc_sizes() -> &'static Mutex<HashMap<usize, usize>> {
    FREETYPE_ALLOC_SIZES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn track_alloc(pointer: *mut c_void, size: usize) {
    if size == 0 || pointer.is_null() {
        return;
    }
    FREETYPE_MEMORY_USAGE.fetch_add(size, Ordering::Relaxed);
    alloc_sizes().lock().insert(pointer as usize, size);
}

fn track_free(pointer: *mut c_void) {
    if pointer.is_null() {
        return;
    }
    if let Some(size) = alloc_sizes().lock().remove(&(pointer as usize)) {
        FREETYPE_MEMORY_USAGE.fetch_sub(size, Ordering::Relaxed);
    }
}

extern "C" fn ft_alloc(_: FT_Memory, req_size: c_long) -> *mut c_void {
    if req_size <= 0 {
        return ptr::null_mut();
    }
    unsafe {
        let pointer = malloc(req_size as usize);
        if !pointer.is_null() {
            track_alloc(pointer, req_size as usize);
        }
        pointer
    }
}

extern "C" fn ft_free(_: FT_Memory, pointer: *mut c_void) {
    if pointer.is_null() {
        return;
    }
    track_free(pointer);
    unsafe {
        free(pointer as *mut _);
    }
}

extern "C" fn ft_realloc(
    _: FT_Memory,
    old_size: c_long,
    new_req_size: c_long,
    old_pointer: *mut c_void,
) -> *mut c_void {
    if new_req_size <= 0 {
        if !old_pointer.is_null() {
            track_free(old_pointer);
            unsafe {
                free(old_pointer as *mut _);
            }
        }
        return ptr::null_mut();
    }

    let old_tracked = if old_pointer.is_null() {
        0
    } else if let Some(size) = alloc_sizes().lock().remove(&(old_pointer as usize)) {
        FREETYPE_MEMORY_USAGE.fetch_sub(size, Ordering::Relaxed);
        size
    } else if old_size > 0 {
        old_size as usize
    } else {
        0
    };
    let _ = old_tracked;

    unsafe {
        let new_pointer = if old_pointer.is_null() {
            malloc(new_req_size as usize)
        } else {
            realloc(old_pointer, new_req_size as usize)
        };
        if !new_pointer.is_null() {
            track_alloc(new_pointer, new_req_size as usize);
        }
        new_pointer
    }
}

/// A FreeType library handle to be used for creating and dropping FreeType font faces.
/// It is very important that this handle lives as long as the faces themselves, which
/// is why only one of these is created for the entire execution of Servo and never
/// dropped during execution.
#[derive(Clone, Debug)]
pub(crate) struct FreeTypeLibraryHandle {
    pub(crate) freetype_library: FT_Library,
    freetype_memory: FT_Memory,
}

unsafe impl Sync for FreeTypeLibraryHandle {}
unsafe impl Send for FreeTypeLibraryHandle {}

impl Drop for FreeTypeLibraryHandle {
    #[expect(unused)]
    fn drop(&mut self) {
        assert!(!self.freetype_library.is_null());
        unsafe {
            FT_Done_Library(self.freetype_library);
            Box::from_raw(self.freetype_memory);
        }
    }
}

impl MallocSizeOf for FreeTypeLibraryHandle {
    fn size_of(&self, _ops: &mut MallocSizeOfOps) -> usize {
        // Do not call ops.malloc_size_of on FT_Library / FT_Memory pointers: that uses
        // jemalloc metadata internally. FreeType bytes are already tracked in
        // FREETYPE_MEMORY_USAGE via the hooks above.
        FREETYPE_MEMORY_USAGE.load(Ordering::Relaxed)
    }
}

impl FreeTypeLibraryHandle {
    /// Get the shared FreeType library handle. This is protected by a mutex because according to
    /// the FreeType documentation:
    ///
    /// > [Since 2.5.6] In multi-threaded applications it is easiest to use one FT_Library object per
    /// > thread. In case this is too cumbersome, a single FT_Library object across threads is possible
    /// > also, as long as a mutex lock is used around FT_New_Face and FT_Done_Face.
    ///
    /// See <https://freetype.org/freetype2/docs/reference/ft2-library_setup.html>.
    pub(crate) fn get() -> &'static ReentrantMutex<FreeTypeLibraryHandle> {
        FREETYPE_LIBRARY_HANDLE.get_or_init(|| {
            let freetype_memory = Box::into_raw(Box::new(FT_MemoryRec {
                user: ptr::null_mut(),
                alloc: ft_alloc,
                free: ft_free,
                realloc: ft_realloc,
            }));
            unsafe {
                let mut freetype_library: FT_Library = ptr::null_mut();
                let result = FT_New_Library(freetype_memory, &mut freetype_library);
                if 0 != result {
                    panic!("Unable to initialize FreeType library");
                }
                FT_Add_Default_Modules(freetype_library);
                ReentrantMutex::new(FreeTypeLibraryHandle {
                    freetype_library,
                    freetype_memory,
                })
            }
        })
    }
}
