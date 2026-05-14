//
//  WeatherOverlayView.swift
//  AerialScreenSaverExtension
//
//  SwiftUI weather overlay supporting current conditions and forecast modes.
//

import SwiftUI

/// Per-instance settings extracted from OverlayInstance.typeSettings
struct WeatherViewConfig {
    let degree: String
    let mode: String
    let showHumidity: Bool
    let showWind: Bool
    let showCity: Bool
    /// Wind unit: "kmh" | "mph" | "ms". Fully independent of `degree`.
    let windUnit: String
    let fontName: String
    let fontSize: Double

    init(instance: OverlayInstance) {
        degree = instance.typeSettings["degree"]?.asString ?? "celsius"
        mode = instance.typeSettings["mode"]?.asString ?? "current"
        showHumidity = instance.typeSettings["showHumidity"]?.asBool ?? true
        showWind = instance.typeSettings["showWind"]?.asBool ?? false
        showCity = instance.typeSettings["showCity"]?.asBool ?? true
        windUnit = instance.typeSettings["windUnit"]?.asString ?? "kmh"
        fontName = instance.fontName
        fontSize = instance.fontSize
    }

    /// Literal init for SwiftUI previews and tests.
    init(degree: String, mode: String, showHumidity: Bool, showWind: Bool, showCity: Bool,
         fontName: String, fontSize: Double, windUnit: String = "kmh") {
        self.degree = degree
        self.mode = mode
        self.showHumidity = showHumidity
        self.showWind = showWind
        self.showCity = showCity
        self.windUnit = windUnit
        self.fontName = fontName
        self.fontSize = fontSize
    }

    var isCelsius: Bool { degree == "celsius" }
}

struct WeatherOverlayView: View {
    let weatherData: OWeather?
    let forecastData: ForecastElement?
    let viewConfig: WeatherViewConfig
    private let useMonochrome = false

    /// Per-instance init
    init(instance: OverlayInstance, weatherData: OWeather?, forecastData: ForecastElement?) {
        self.weatherData = weatherData
        self.forecastData = forecastData
        self.viewConfig = WeatherViewConfig(instance: instance)
    }

    /// Literal init for SwiftUI previews.
    init(weatherData: OWeather?, forecastData: ForecastElement?, viewConfig: WeatherViewConfig) {
        self.weatherData = weatherData
        self.forecastData = forecastData
        self.viewConfig = viewConfig
    }

    private var fontSize: Double { viewConfig.fontSize }

    var body: some View {
        if viewConfig.mode == "current" {
            currentWeatherView()
        } else {
            forecastWeatherView()
        }
    }

    // MARK: - Current Weather

    @ViewBuilder
    private func currentWeatherView() -> some View {
        guard let weather = weatherData, let main = weather.main else {
            return AnyView(EmptyView())
        }

        let conditionCode = weather.weather?.first?.id ?? 800
        let isNight: Bool = {
            if let dt = weather.dt, let sys = weather.sys {
                return WeatherSymbols.isNight(dt: dt, sunrise: sys.sunrise, sunset: sys.sunset)
            }
            return false
        }()

        let symbolName = weatherSymbolName(conditionCode: conditionCode, isNight: isNight)

        return AnyView(
            HStack(alignment: .center, spacing: fontSize * 0.3) {
                // Weather icon — spans full height of the text column
                Group {
                    if useMonochrome {
                        Image(systemName: symbolName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: symbolName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .symbolRenderingMode(.multicolor)
                    }
                }
                .frame(maxHeight: 110)

                // Text info column
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatTemp(main.temp))
                        .font(weatherFont(size: fontSize))

                    Text("(\(formatTemp(main.feelsLike)))")
                        .font(weatherFont(size: fontSize / 2.2))

                    // Wind + humidity row
                    if viewConfig.showWind || viewConfig.showHumidity {
                        HStack(spacing: fontSize * 0.3) {
                            if viewConfig.showWind, let wind = weather.wind {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: fontSize / 2.8))
                                        .rotationEffect(.degrees(Double(180 + wind.deg)))

                                    Text(formatWind(wind.speed))
                                        .font(weatherFont(size: fontSize / 2.2))
                                }
                            }

                            if viewConfig.showHumidity {
                                HStack(spacing: 2) {
                                    Image(systemName: "humidity")
                                        .font(.system(size: fontSize / 2.8))

                                    Text("\(Int(main.humidity))%")
                                        .font(weatherFont(size: fontSize / 2.2))
                                }
                            }
                        }
                    }

                    // City name
                    if viewConfig.showCity, let name = weather.name {
                        Text(name)
                            .font(weatherFont(size: fontSize / 1.5))
                    }
                }
            }
            //.fixedSize(horizontal: false, vertical: true)
        )
    }

    // MARK: - Forecast Weather

    @ViewBuilder
    private func forecastWeatherView() -> some View {
        guard let forecast = forecastData, let flist = forecast.list, !flist.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(alignment: .bottom, spacing: 4) {
                // Current conditions column (if available)
                if weatherData != nil {
                    currentWeatherView()
                        .padding(.trailing, 4)
                }

                // Forecast columns
                if viewConfig.mode == "forecast6hours" {
                    hourlyForecastView(flist: flist)
                } else {
                    dailyForecastView(flist: flist)
                }
            }
        )
    }

    @ViewBuilder
    private func hourlyForecastView(flist: [FList]) -> some View {
        let count = min(6, flist.count)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<count, id: \.self) { idx in
                hourColumn(hour: flist[idx])
            }
        }
    }

    @ViewBuilder
    private func dailyForecastView(flist: [FList]) -> some View {
        let days = viewConfig.mode == "forecast3days" ? 3 : 5
        let breakIndex = detectDayChange(list: flist)
        let columnSize = fontSize * 2

        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<days, id: \.self) { dayIdx in
                if dayIdx == 0 {
                    dayColumn(slice: Array(flist[0..<min(breakIndex, flist.count)]),
                              columnSize: columnSize)
                } else {
                    let start = breakIndex + (8 * (dayIdx - 1))
                    let end = min(start + 8, flist.count)
                    if start < flist.count {
                        dayColumn(slice: Array(flist[start..<end]),
                                  columnSize: columnSize)
                    }
                }
            }
        }
    }

    // MARK: - Forecast Columns

    @ViewBuilder
    private func hourColumn(hour: FList) -> some View {
        let isNight = hour.sys?.pod == "n"
        let conditionCode = hour.weather?.first?.id ?? 800
        let symbolName = weatherSymbolName(conditionCode: conditionCode, isNight: isNight)
        let colFont = weatherFont(size: fontSize / 2)

        VStack(spacing: 1) {
            weatherIcon(symbolName: symbolName, size: fontSize * 0.8)

            Text(formatTemp(hour.main?.temp))
                .font(colFont)

            Text(formatTemp(hour.main?.feelsLike))
                .font(colFont)
                .opacity(0.7)

            if viewConfig.showHumidity, let humidity = hour.main?.humidity {
                Text("\(humidity)%")
                    .font(colFont)
                    .opacity(0.7)
            }

            if viewConfig.showWind, let wind = hour.wind, let speed = wind.speed {
                HStack(spacing: 1) {
                    if let deg = wind.deg {
                        Image(systemName: "arrow.up")
                            .font(.system(size: fontSize / 4))
                            .opacity(0.7)
                            .rotationEffect(.degrees(Double(180 + deg)))
                    }
                    Text(formatWindShort(speed))
                        .font(colFont)
                        .opacity(0.7)
                }
            }

            Text(hourString(from: hour.dt))
                .font(colFont)
        }
        .frame(minWidth: fontSize * 1.8)
    }

    @ViewBuilder
    private func dayColumn(slice: [FList], columnSize: Double) -> some View {
        let (tmin, tmax) = tempRange(from: slice)
        let midpoint = slice[slice.count / 2]
        let conditionCode = midpoint.weather?.first?.id ?? 800
        let symbolName = weatherSymbolName(conditionCode: conditionCode, isNight: false)
        let colFont = weatherFont(size: fontSize / 2)

        VStack(spacing: 1) {
            weatherIcon(symbolName: symbolName, size: fontSize * 0.8)

            Text(formatTemp(tmax))
                .font(colFont)

            Text(formatTemp(tmin))
                .font(colFont)
                .opacity(0.7)

            if viewConfig.showHumidity, let humidity = midpoint.main?.humidity {
                Text("\(humidity)%")
                    .font(colFont)
                    .opacity(0.7)
            }

            if viewConfig.showWind, let wind = midpoint.wind, let speed = wind.speed {
                HStack(spacing: 1) {
                    if let deg = wind.deg {
                        Image(systemName: "arrow.up")
                            .font(.system(size: fontSize / 4))
                            .opacity(0.7)
                            .rotationEffect(.degrees(Double(180 + deg)))
                    }
                    Text(formatWindShort(speed))
                        .font(colFont)
                        .opacity(0.7)
                }
            }

            Text(dayString(from: slice.first?.dt))
                .font(colFont)
        }
        .frame(minWidth: fontSize * 1.8)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private func weatherIcon(symbolName: String, size: Double) -> some View {
        if useMonochrome {
            Image(systemName: symbolName)
                .font(.system(size: size * 0.8))
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size * 0.8))
                .symbolRenderingMode(.multicolor)
        }
    }

    // MARK: - Helpers

    private func weatherFont(size: Double) -> Font {
        if viewConfig.fontName == "system" {
            return .system(size: size, weight: .medium)
        }
        return .custom(viewConfig.fontName, size: size)
    }

    private func weatherSymbolName(conditionCode: Int, isNight: Bool) -> String {
        if useMonochrome {
            return WeatherSymbols.symbolName(for: conditionCode, isNight: isNight)
        } else {
            return WeatherSymbols.colorSymbolName(for: conditionCode, isNight: isNight)
        }
    }

    /// Convert metric temp (°C) to display units
    private func formatTemp(_ temp: Double?) -> String {
        guard let temp = temp else { return "--°" }
        return formatTemp(temp)
    }

    private func formatTemp(_ temp: Double) -> String {
        if viewConfig.isCelsius {
            return "\(temp.rounded(toPlaces: 1))°"
        } else {
            let f = temp * 9.0 / 5.0 + 32.0
            return "\(Int(f.rounded()))°"
        }
    }

    /// Convert metric wind speed (m/s, OpenWeather's default for
    /// metric units) to the user's chosen unit.
    private func formatWind(_ speed: Double) -> String {
        switch viewConfig.windUnit {
        case "mph": return "\(Int(speed * 2.237)) mph"
        case "ms":  return "\(Int(speed.rounded())) m/s"
        default:    return "\(Int(speed * 3.6)) km/h"   // kmh
        }
    }

    private func formatWindShort(_ speed: Double) -> String {
        switch viewConfig.windUnit {
        case "mph": return "\(Int(speed * 2.237))"
        case "ms":  return "\(Int(speed.rounded()))"
        default:    return "\(Int(speed * 3.6))"
        }
    }

    private func tempRange(from slice: [FList]) -> (min: Double?, max: Double?) {
        var tmin: Double?
        var tmax: Double?
        for element in slice {
            if let tempMin = element.main?.tempMin {
                if tmin == nil || tempMin < tmin! { tmin = tempMin }
            }
            if let tempMax = element.main?.tempMax {
                if tmax == nil || tempMax > tmax! { tmax = tempMax }
            }
        }
        return (tmin, tmax)
    }

    private func detectDayChange(list: [FList]) -> Int {
        var firstDay: String?
        for (index, item) in list.enumerated() {
            guard let dt = item.dt else { continue }
            let day = dayString(from: dt)
            if firstDay == nil {
                firstDay = day
            } else if day != firstDay {
                return index
            }
        }
        return 1
    }

    private func dayString(from timestamp: Int?) -> String {
        guard let timestamp = timestamp else { return "" }
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let formatter = DateFormatter()
        var locale = Locale(identifier: Locale.preferredLanguages[0])
        if PrefsAdvanced.ciOverrideLanguage != "" {
            locale = Locale(identifier: PrefsAdvanced.ciOverrideLanguage)
        }
        formatter.locale = locale
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }

    private func hourString(from timestamp: Int?) -> String {
        guard let timestamp = timestamp else { return "" }
        let date = Date(timeIntervalSince1970: Double(timestamp))
        let formatter = DateFormatter()
        var locale = Locale(identifier: Locale.preferredLanguages[0])
        if PrefsAdvanced.ciOverrideLanguage != "" {
            locale = Locale(identifier: PrefsAdvanced.ciOverrideLanguage)
        }
        formatter.locale = locale
        formatter.dateFormat = "HH"
        return formatter.string(from: date) + "h"
    }
}

// MARK: - Previews

private let previewSunnyDay = OWeather(
    coord: OWCoord(lon: 2.35, lat: 48.86),
    weather: [OWWeather(id: 800, main: "Clear", weatherDescription: "clear sky", icon: "01d")],
    base: "stations",
    main: OWMain(temp: 22.0, feelsLike: 20.5, tempMin: 19.0, tempMax: 24.0, pressure: 1015, humidity: 55),
    visibility: 10000,
    wind: OWWind(speed: 3.5, deg: 220, gust: 5.0),
    clouds: OWClouds(all: 0),
    dt: 1_700_000_000,
    sys: OWSys(type: 2, id: 2041, country: "FR", sunrise: 1_699_944_000, sunset: 1_700_020_000),
    timezone: 3600,
    id: 2_988_507,
    name: "Paris",
    cod: 200
)

private let previewRainyNight = OWeather(
    coord: OWCoord(lon: 2.35, lat: 48.86),
    weather: [OWWeather(id: 501, main: "Rain", weatherDescription: "moderate rain", icon: "10n")],
    base: "stations",
    main: OWMain(temp: 11.3, feelsLike: 9.8, tempMin: 10.0, tempMax: 13.0, pressure: 1008, humidity: 88),
    visibility: 5000,
    wind: OWWind(speed: 6.2, deg: 310, gust: 9.0),
    clouds: OWClouds(all: 90),
    dt: 1_700_030_000,   // past sunset
    sys: OWSys(type: 2, id: 2041, country: "FR", sunrise: 1_699_944_000, sunset: 1_700_020_000),
    timezone: 3600,
    id: 2_988_507,
    name: "Paris",
    cod: 200
)

private let previewForecast: ForecastElement = {
    let baseTime = 1_700_000_000
    let entries: [FList] = (0..<6).map { i in
        let dt = baseTime + i * 10800  // 3-hour intervals
        let temp = 18.0 + Double(i) * 1.5
        let codes = [800, 801, 802, 500, 501, 800]
        let pods = ["d", "d", "d", "n", "n", "n"]
        let descs = ["clear sky", "few clouds", "scattered clouds", "light rain", "moderate rain", "clear sky"]
        let icons = ["01d", "02d", "03d", "10n", "10n", "01n"]
        return FList(
            dt: dt,
            main: MainClass(temp: temp, feelsLike: temp - 1.5, tempMin: temp - 2.0, tempMax: temp + 2.0,
                            pressure: 1013, seaLevel: 1013, grndLevel: 1010, humidity: 60 + i * 3, tempKf: 0),
            weather: [OWWeather(id: codes[i], main: descs[i], weatherDescription: descs[i], icon: icons[i])],
            clouds: Clouds(all: i * 15),
            wind: Wind(speed: 3.0 + Double(i) * 0.5, deg: 180 + i * 20, gust: 5.0),
            visibility: 10000,
            pop: Double(i) * 0.1,
            sys: Sys(pod: pods[i]),
            dtTxt: "2023-11-15 \(12 + i * 3):00:00",
            rain: nil
        )
    }
    return ForecastElement(
        cod: "200",
        message: 0,
        cnt: 6,
        list: entries,
        city: City(id: 2_988_507, name: "Paris", coord: Coord(lat: 48.86, lon: 2.35),
                   country: "FR", population: 2_138_551, timezone: 3600,
                   sunrise: 1_699_944_000, sunset: 1_700_020_000)
    )
}()

private let previewConfig = WeatherViewConfig(
    degree: "celsius", mode: "current",
    showHumidity: true, showWind: true, showCity: true,
    fontName: "Helvetica Neue Medium", fontSize: 30
)

private let previewForecastConfig = WeatherViewConfig(
    degree: "celsius", mode: "forecast6hours",
    showHumidity: true, showWind: true, showCity: true,
    fontName: "Helvetica Neue Medium", fontSize: 30
)

#Preview("Current Weather") {
    WeatherOverlayView(weatherData: previewSunnyDay, forecastData: nil, viewConfig: previewConfig)
        .padding()
        .background(Color.black)
}

#Preview("Current Weather Night") {
    WeatherOverlayView(weatherData: previewRainyNight, forecastData: nil, viewConfig: previewConfig)
        .padding()
        .background(Color.black)
}

#Preview("Forecast 6h") {
    WeatherOverlayView(weatherData: previewSunnyDay, forecastData: previewForecast, viewConfig: previewForecastConfig)
        .padding()
        .background(Color.black)
}
