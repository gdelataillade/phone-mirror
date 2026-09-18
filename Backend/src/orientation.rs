//! Orientation queries must never block packet reception or video feedback.
use std::{future::Future, time::Duration};
use tokio::{sync::watch, time::Instant};

pub trait Source: Send {
    fn read(&mut self) -> impl Future<Output = super::Result<u32>> + Send;
}

#[derive(Clone, Copy)]
pub struct Observation {
    pub value: u32,
    pub requested: Instant,
    pub completed: Instant,
    pub queries: u64,
    pub max_ms: u64,
    pub failed: bool,
}
impl Observation {
    pub fn initial() -> Self {
        Self {
            value: 4,
            requested: Instant::now(),
            completed: Instant::now(),
            queries: 0,
            max_ms: 0,
            failed: false,
        }
    }
    pub fn value_for(&self, config_changed: Instant, now: Instant) -> u32 {
        // After a codec change, require a query begun after that change. Old
        // orientation must not enable touch on a newly rotated picture.
        if self.failed
            || self.queries == 0
            || self.requested < config_changed
            || now.duration_since(self.completed) > Duration::from_millis(1250)
        {
            4
        } else {
            self.value
        }
    }
}

pub async fn run(
    mut source: impl Source,
    observations: watch::Sender<Observation>,
    mut stop: watch::Receiver<bool>,
) {
    let mut state = Observation::initial();
    let mut timer = tokio::time::interval(Duration::from_millis(500));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! { biased;
            _ = super::cancelled(&mut stop) => return,
            _ = timer.tick() => {}
        }
        state.requested = Instant::now();
        let result = tokio::select! { biased;
            _ = super::cancelled(&mut stop) => return,
            result = tokio::time::timeout(Duration::from_millis(750), source.read()) => result,
        };
        state.completed = Instant::now();
        state.queries += 1;
        state.max_ms = state
            .max_ms
            .max(state.completed.duration_since(state.requested).as_millis() as u64);
        state.failed = !matches!(result, Ok(Ok(_)));
        state.value = match result {
            Ok(Ok(value)) => value,
            _ => 4,
        };
        observations.send_replace(state);
        // A timed-out request may leave a late response on its stream. Never
        // reuse it; the owning session will reconnect with a new service.
        if state.failed {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Slow;
    impl Source for Slow {
        async fn read(&mut self) -> super::super::Result<u32> {
            tokio::time::sleep(Duration::from_millis(600)).await;
            Ok(2)
        }
    }
    struct Hung;
    impl Source for Hung {
        async fn read(&mut self) -> super::super::Result<u32> {
            std::future::pending().await
        }
    }

    #[tokio::test(start_paused = true)]
    async fn slow_orientation_does_not_block_media_and_old_geometry_is_rejected() {
        let began = Instant::now();
        let (tx, rx) = watch::channel(Observation::initial());
        let (stop, stop_rx) = watch::channel(false);
        let task = tokio::spawn(run(Slow, tx, stop_rx));
        let mut received = 0;
        for _ in 0..10 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            received += 1; // Media remains independently schedulable while the query waits.
        }
        assert_eq!(received, 10);
        assert_eq!(rx.borrow().queries, 0);
        tokio::time::sleep(Duration::from_millis(150)).await;
        let state = *rx.borrow();
        assert_eq!(state.value_for(began, Instant::now()), 2);
        assert_eq!(state.value_for(Instant::now(), Instant::now()), 4);
        stop.send(true).unwrap();
        task.await.unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn timeout_invalidates_orientation_and_does_not_reuse_the_stream() {
        let (tx, rx) = watch::channel(Observation::initial());
        let (_stop, stop_rx) = watch::channel(false);
        run(Hung, tx, stop_rx).await;
        assert!(rx.borrow().failed);
        assert_eq!(rx.borrow().queries, 1);
        assert_eq!(rx.borrow().value, 4);
    }

    #[tokio::test(start_paused = true)]
    async fn stop_cancels_an_outstanding_query_promptly() {
        let (tx, _rx) = watch::channel(Observation::initial());
        let (stop, stop_rx) = watch::channel(false);
        let task = tokio::spawn(run(Hung, tx, stop_rx));
        tokio::task::yield_now().await;
        let began = Instant::now();
        stop.send(true).unwrap();
        task.await.unwrap();
        assert_eq!(began.elapsed(), Duration::ZERO);
    }
}
