//! Locks that keep working after a panic.
//!
//! A panic while a std lock is held poisons it, and `lock().unwrap()` then panics in every later
//! caller, so one bug would become a crash on every call from the app. What these locks guard is
//! state the core rebuilds or overwrites (snapshots, caches, settings), so a poisoned lock is
//! simply used as it was left.

use std::sync::{Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

pub(crate) trait MutexExt<T> {
    fn locked(&self) -> MutexGuard<'_, T>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn locked(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

pub(crate) trait RwLockExt<T> {
    fn read_now(&self) -> RwLockReadGuard<'_, T>;
    fn write_now(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T> RwLockExt<T> for RwLock<T> {
    fn read_now(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(PoisonError::into_inner)
    }

    fn write_now(&self) -> RwLockWriteGuard<'_, T> {
        self.write().unwrap_or_else(PoisonError::into_inner)
    }
}
