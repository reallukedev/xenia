use std::{future::Future, sync::LazyLock};

use tokio::runtime::Runtime;

/// The one runtime all of Xenia's async work runs on.
///
/// UniFFI futures are polled by the app's own executor (Swift concurrency, Kotlin coroutines),
/// which knows nothing about Tokio, so every exported async function hands its work to this
/// runtime and awaits the result. Long-lived tasks (sync, list streams) are spawned here too.
static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("xenia-core")
        // Parsing HTML from other people's messages recurses through the elements; the default
        // 2 MiB leaves little room for a hostile one. Reserved, not used, until needed.
        .thread_stack_size(8 * 1024 * 1024)
        .build()
        .expect("the Tokio runtime starts")
});

/// Runs `future` on Xenia's runtime and waits for it from any executor.
pub(crate) async fn run<F, T>(future: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match RUNTIME.spawn(future).await {
        Ok(value) => value,
        // A panic inside the task: surface it as a panic here too, which UniFFI turns into an
        // error for the caller instead of aborting the app.
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

/// Starts a background task on Xenia's runtime.
pub(crate) fn spawn<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    RUNTIME.spawn(future)
}

/// A background task that stops when its handle is dropped.
#[derive(Debug)]
pub(crate) struct TaskGuard(tokio::task::JoinHandle<()>);

impl TaskGuard {
    pub(crate) fn spawn<F>(future: F) -> Self
    where
        F: Future<Output = ()> + Send + 'static,
    {
        Self(spawn(future))
    }
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}
