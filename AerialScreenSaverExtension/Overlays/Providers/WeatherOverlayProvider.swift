//
//  WeatherOverlayProvider.swift
//  AerialScreenSaverExtension
//
//  Provider for weather overlay type. Wraps the existing WeatherOverlayView.
//

import SwiftUI
import CoreLocation
import AppKit

struct WeatherOverlayProvider: OverlayTypeProvider {
    static let kind: OverlayKind = .weather

    static func makeView(instance: OverlayInstance, state: OverlayState) -> AnyView {
        let weather = state.weatherDataByInstance[instance.id] ?? (state.isPreview ? Self.previewWeather : nil)
        let forecast = state.forecastDataByInstance[instance.id] ?? (state.isPreview ? Self.previewForecast : nil)
        return AnyView(
            WeatherOverlayView(
                instance: instance,
                weatherData: weather,
                forecastData: forecast
            )
        )
    }

    private static let previewWeather = OWeather(
        coord: OWCoord(lon: -122.42, lat: 37.77),
        weather: [OWWeather(id: 802, main: "Clouds", weatherDescription: "scattered clouds", icon: "03d")],
        base: "stations",
        main: OWMain(temp: 18.5, feelsLike: 17.2, tempMin: 16.0, tempMax: 21.0, pressure: 1013, humidity: 62),
        visibility: 10000,
        wind: OWWind(speed: 4.1, deg: 270, gust: 6.0),
        clouds: OWClouds(all: 40),
        dt: 1_700_000_000,
        sys: OWSys(type: 2, id: 2000, country: "US", sunrise: 1_699_970_000, sunset: 1_700_010_000),
        timezone: -28800,
        id: 5_391_959,
        name: "San Francisco",
        cod: 200
    )

    private static let previewForecast: ForecastElement = {
        let baseTime = 1_700_000_000
        let entries: [FList] = (0..<6).map { i in
            let dt = baseTime + i * 10800
            let temp = 16.0 + Double(i) * 1.2
            let codes = [802, 800, 801, 500, 802, 800]
            let pods = ["d", "d", "d", "n", "n", "n"]
            return FList(
                dt: dt,
                main: MainClass(temp: temp, feelsLike: temp - 1.5, tempMin: temp - 2.0, tempMax: temp + 2.0,
                                pressure: 1013, seaLevel: 1013, grndLevel: 1010, humidity: 55 + i * 3, tempKf: 0),
                weather: [OWWeather(id: codes[i], main: "Weather", weatherDescription: "weather", icon: "03d")],
                clouds: Clouds(all: i * 10),
                wind: Wind(speed: 3.0 + Double(i) * 0.5, deg: 200 + i * 15, gust: 5.0),
                visibility: 10000,
                pop: Double(i) * 0.1,
                sys: Sys(pod: pods[i]),
                dtTxt: "2023-11-15 \(12 + i * 3):00:00",
                rain: nil
            )
        }
        return ForecastElement(
            cod: "200", message: 0, cnt: 6, list: entries,
            city: City(id: 5_391_959, name: "San Francisco", coord: Coord(lat: 37.77, lon: -122.42),
                       country: "US", population: 874_961, timezone: -28800,
                       sunrise: 1_699_970_000, sunset: 1_700_010_000)
        )
    }()

    static func makeSettingsView(instance: Binding<OverlayInstance>) -> AnyView {
        AnyView(WeatherSettingsContent(instance: instance))
    }
}

private struct WeatherSettingsContent: View {
    @Binding var instance: OverlayInstance

    /// Cached Core Location authorization status. `Current Location`
    /// mode reverse-geocodes the user's coordinates to find their
    /// city; without Location authorization OpenWeather can't be
    /// queried for "where I am" weather. Refreshed on appear and
    /// whenever the app regains focus (so the user opening System
    /// Settings, granting, and coming back sees the warning clear).
    @State private var locationAuthStatus: CLAuthorizationStatus = CLLocationManager().authorizationStatus

    private var locationGrantNeeded: Bool {
        locationMode == "current"
            && (locationAuthStatus == .notDetermined
                || locationAuthStatus == .denied
                || locationAuthStatus == .restricted)
    }

    private var degree: String {
        instance.typeSettings["degree"]?.asString ?? "celsius"
    }

    private var mode: String {
        instance.typeSettings["mode"]?.asString ?? "current"
    }

    private var showHumidity: Bool {
        instance.typeSettings["showHumidity"]?.asBool ?? true
    }

    private var showWind: Bool {
        instance.typeSettings["showWind"]?.asBool ?? false
    }

    private var windUnit: String {
        instance.typeSettings["windUnit"]?.asString ?? "kmh"
    }

    private var showCity: Bool {
        instance.typeSettings["showCity"]?.asBool ?? true
    }

    private var locationMode: String {
        instance.typeSettings["locationMode"]?.asString ?? "current"
    }

    private var locationString: String {
        instance.typeSettings["locationString"]?.asString ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Location", selection: Binding(
                get: { locationMode },
                set: { instance.typeSettings["locationMode"] = .string($0) }
            )) {
                Text("Current Location").tag("current")
                Text("Manual City").tag("manual")
            }

            if locationMode == "manual" {
                TextField("City name (e.g. Tokyo, JP)", text: Binding(
                    get: { locationString },
                    set: { instance.typeSettings["locationString"] = .string($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            if locationGrantNeeded {
                locationPermissionWarning
            }

            Picker("Units", selection: Binding(
                get: { degree },
                set: { instance.typeSettings["degree"] = .string($0) }
            )) {
                Text("Celsius").tag("celsius")
                Text("Fahrenheit").tag("fahrenheit")
            }

            Picker("Mode", selection: Binding(
                get: { mode },
                set: { instance.typeSettings["mode"] = .string($0) }
            )) {
                Text("Current").tag("current")
                Text("6h Forecast").tag("forecast6hours")
                Text("3-day Forecast").tag("forecast3days")
                Text("5-day Forecast").tag("forecast5days")
            }

            Toggle("Show humidity", isOn: Binding(
                get: { showHumidity },
                set: { instance.typeSettings["showHumidity"] = .bool($0) }
            ))

            Toggle("Show wind", isOn: Binding(
                get: { showWind },
                set: { instance.typeSettings["showWind"] = .bool($0) }
            ))

            if showWind {
                Picker("Wind unit", selection: Binding(
                    get: { windUnit },
                    set: { instance.typeSettings["windUnit"] = .string($0) }
                )) {
                    Text("km/h").tag("kmh")
                    Text("mph").tag("mph")
                    Text("m/s").tag("ms")
                }
            }

            Toggle("Show city name", isOn: Binding(
                get: { showCity },
                set: { instance.typeSettings["showCity"] = .bool($0) }
            ))
        }
        .onAppear { refreshLocationAuth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User likely came back from System Settings after
            // granting / denying. Re-read so the warning clears
            // without requiring them to close + reopen the inspector.
            refreshLocationAuth()
        }
    }

    /// Inline warning shown when "Current Location" is selected but
    /// Core Location hasn't been authorized for the Companion. Mirrors
    /// the equivalent affordance in `CacheSettingsPanel` — same
    /// visual, same one-click deep link into Privacy & Security.
    private var locationPermissionWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Location permission needed")
                    .font(.system(size: 12, weight: .semibold))
                Text("Aerial needs Location access to detect your current city for weather. Without it, weather won't appear.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Location Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func refreshLocationAuth() {
        locationAuthStatus = CLLocationManager().authorizationStatus
    }
}
