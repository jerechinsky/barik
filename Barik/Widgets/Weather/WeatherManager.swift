import Combine
import Foundation

struct WeatherData {
    let temperature: Double
    let weatherCode: Int
}

struct HourlyWeatherData: Identifiable {
    let time: Date
    let temperature: Double
    let weatherCode: Int
    let precipitationProbability: Int?
    let isNow: Bool

    var id: Date { time }
}

struct DailyWeatherData: Identifiable {
    let date: Date
    let minimumTemperature: Double
    let maximumTemperature: Double
    let weatherCode: Int
    let precipitationProbability: Int?

    var id: Date { date }
}

struct SunlightData {
    let sunrise: Date
    let sunset: Date
    let timeZone: TimeZone

    var daylightMinutes: Int {
        Int(sunset.timeIntervalSince(sunrise) / 60)
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Int]?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case precipitationProbability = "precipitation_probability"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let weatherCode: [Int]
        let temperature2mMax: [Double]
        let temperature2mMin: [Double]
        let precipitationProbabilityMax: [Int]?
        let sunrise: [String]
        let sunset: [String]

        enum CodingKeys: String, CodingKey {
            case time, sunrise, sunset
            case weatherCode = "weather_code"
            case temperature2mMax = "temperature_2m_max"
            case temperature2mMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
    }

    let current: Current
    let hourly: Hourly?
    let daily: Daily?
    let utcOffsetSeconds: Int

    enum CodingKeys: String, CodingKey {
        case current, hourly, daily
        case utcOffsetSeconds = "utc_offset_seconds"
    }
}

private struct CachedWeather: Codable {
    let latitude: Double
    let longitude: Double
    let temperature: Double
    let weatherCode: Int
    let savedAt: Date
}

private enum WeatherFetchError: Error {
    case curlFailed(Int32, String)
}

@MainActor
final class WeatherManager: ObservableObject {
    @Published var weatherData: WeatherData?
    @Published var hourlyForecast: [HourlyWeatherData] = []
    @Published var dailyForecast: [DailyWeatherData] = []
    @Published var sunlightData: SunlightData?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private static let cacheKey = "barik.weather.last-success"
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60
    private static let retryDelayNanoseconds: UInt64 = 60 * 1_000_000_000

    private var latitude: Double
    private var longitude: Double
    private var timer: Timer?
    private var fetchTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init(latitude: Double = 50.0755, longitude: Double = 14.4378) {
        self.latitude = latitude
        self.longitude = longitude
        loadCachedWeather()
        fetchWeather()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchWeather()
            }
        }
    }

    deinit {
        timer?.invalidate()
        fetchTask?.cancel()
        retryTask?.cancel()
    }

    func updateCoordinates(latitude: Double, longitude: Double) {
        guard latitude != self.latitude || longitude != self.longitude else { return }

        fetchTask?.cancel()
        retryTask?.cancel()
        fetchTask = nil
        retryTask = nil
        self.latitude = latitude
        self.longitude = longitude
        weatherData = nil
        hourlyForecast = []
        dailyForecast = []
        sunlightData = nil
        loadCachedWeather()
        fetchWeather()
    }

    func fetchWeather() {
        guard fetchTask == nil else { return }

        isLoading = true
        errorMessage = nil
        let urlString =
            "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code&hourly=temperature_2m,weather_code,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset&temperature_unit=celsius&timezone=auto&forecast_days=7"
        guard let url = URL(string: urlString) else {
            isLoading = false
            errorMessage = "Invalid weather location"
            scheduleRetry()
            return
        }

        fetchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let data = try await Self.requestDataUsingCurl(from: url)
                let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                try Task.checkCancellation()

                let current = WeatherData(
                    temperature: decoded.current.temperature2m,
                    weatherCode: decoded.current.weatherCode
                )
                weatherData = current
                hourlyForecast = Self.makeHourlyForecast(from: decoded.hourly)
                dailyForecast = Self.makeDailyForecast(from: decoded.daily)
                sunlightData = Self.makeSunlightData(
                    from: decoded.daily,
                    utcOffsetSeconds: decoded.utcOffsetSeconds
                )
                isLoading = false
                errorMessage = nil
                fetchTask = nil
                retryTask?.cancel()
                retryTask = nil
                saveCachedWeather(current)
            } catch is CancellationError {
                isLoading = false
                fetchTask = nil
            } catch {
                NSLog("WeatherManager: fetch error: %@", String(describing: error))
                isLoading = false
                errorMessage = "Could not load weather"
                fetchTask = nil
                scheduleRetry()
            }
        }
    }

    private nonisolated static func requestDataUsingCurl(from url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "--silent",
                "--show-error",
                "--fail",
                "--location",
                "--max-time", "15",
                url.absoluteString,
            ]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0, data.isEmpty == false {
                    continuation.resume(returning: data)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errorData, encoding: .utf8) ?? "No response"
                    continuation.resume(
                        throwing: WeatherFetchError.curlFailed(
                            process.terminationStatus,
                            message.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }

        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            retryTask = nil
            fetchWeather()
        }
    }

    private func loadCachedWeather() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(CachedWeather.self, from: data),
              abs(cached.latitude - latitude) < 0.000_001,
              abs(cached.longitude - longitude) < 0.000_001,
              Date().timeIntervalSince(cached.savedAt) <= Self.cacheLifetime else {
            return
        }

        weatherData = WeatherData(
            temperature: cached.temperature,
            weatherCode: cached.weatherCode
        )
    }

    private func saveCachedWeather(_ weather: WeatherData) {
        let cached = CachedWeather(
            latitude: latitude,
            longitude: longitude,
            temperature: weather.temperature,
            weatherCode: weather.weatherCode,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private static func makeHourlyForecast(from hourly: OpenMeteoResponse.Hourly?) -> [HourlyWeatherData] {
        guard let hourly else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = .current

        let now = Date()
        let currentHour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let count = min(hourly.time.count, hourly.temperature2m.count, hourly.weatherCode.count)

        return (0..<count).compactMap { index in
            guard let date = formatter.date(from: hourly.time[index]), date >= currentHour else {
                return nil
            }
            let precipitation = hourly.precipitationProbability.flatMap { values in
                values.indices.contains(index) ? values[index] : nil
            }
            return HourlyWeatherData(
                time: date,
                temperature: hourly.temperature2m[index],
                weatherCode: hourly.weatherCode[index],
                precipitationProbability: precipitation,
                isNow: Calendar.current.isDate(date, equalTo: currentHour, toGranularity: .hour)
            )
        }
    }

    private static func makeDailyForecast(
        from daily: OpenMeteoResponse.Daily?
    ) -> [DailyWeatherData] {
        guard let daily else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let count = min(
            daily.time.count,
            daily.weatherCode.count,
            daily.temperature2mMax.count,
            daily.temperature2mMin.count
        )

        return (0..<count).compactMap { index in
            guard let date = formatter.date(from: daily.time[index]) else { return nil }
            let precipitation = daily.precipitationProbabilityMax.flatMap { values in
                values.indices.contains(index) ? values[index] : nil
            }
            return DailyWeatherData(
                date: date,
                minimumTemperature: daily.temperature2mMin[index],
                maximumTemperature: daily.temperature2mMax[index],
                weatherCode: daily.weatherCode[index],
                precipitationProbability: precipitation
            )
        }
    }

    private static func makeSunlightData(
        from daily: OpenMeteoResponse.Daily?,
        utcOffsetSeconds: Int
    ) -> SunlightData? {
        guard let sunriseString = daily?.sunrise.first,
              let sunsetString = daily?.sunset.first,
              let timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = timeZone

        guard let sunrise = formatter.date(from: sunriseString),
              let sunset = formatter.date(from: sunsetString),
              sunset > sunrise else {
            return nil
        }

        return SunlightData(sunrise: sunrise, sunset: sunset, timeZone: timeZone)
    }
}

extension WeatherManager {
    /// Maps WMO weather codes to SF Symbol names.
    static func symbolName(for code: Int) -> String {
        switch code {
        case 0, 1:
            return "sun.max.fill"
        case 2:
            return "cloud.sun.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 80, 81:
            return "cloud.rain.fill"
        case 65, 82:
            return "cloud.heavyrain.fill"
        case 66, 67:
            return "cloud.sleet.fill"
        case 71, 73, 77, 85:
            return "cloud.snow.fill"
        case 75, 86:
            return "snowflake"
        case 95:
            return "cloud.bolt.fill"
        case 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return "cloud.fill"
        }
    }

    static func conditionName(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Weather"
        }
    }
}
