import AppKit

/// v437: recurring jobs that run on macOS's own background scheduler. The system picks a convenient moment (it waits
/// while the Mac is busy or on a low battery), and the work never runs on the main thread, so nothing you see freezes.
///
/// - Weather: refreshed every half hour, so the page is already current when the notch opens (before, it was only
///   refreshed when the page opened).
/// - Cover cache: covers not used for 45 days are removed once a day.
final class BackgroundJobs {
    private var schedulers: [NSBackgroundActivityScheduler] = []

    func start(weather: WeatherController) {
        guard schedulers.isEmpty else { return }
        schedulers.append(schedule("com.indra.job.weather", every: 30 * 60) { finish in
            Task { @MainActor in
                weather.activate()
                finish()
            }
        })
        schedulers.append(schedule("com.indra.job.cache-trim", every: 24 * 3600) { finish in
            DispatchQueue.global(qos: .utility).async {
                CoverDiskCache.prune()
                finish()
            }
        })
    }

    private func schedule(_ identifier: String,
                          every interval: TimeInterval,
                          _ work: @escaping (@escaping () -> Void) -> Void) -> NSBackgroundActivityScheduler {
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = interval / 4
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            if scheduler.shouldDefer {
                completion(.deferred)
                return
            }
            Trace.log("JOB \(identifier) runs")
            work { completion(.finished) }
        }
        return scheduler
    }
}
