//
//  TimeSettingsPanel.swift
//  Aerial Companion
//
//  Created by Guillaume Louel on 11/03/2026.
//

import SwiftUI

struct TimeSettingsPanel: View {
    @State private var selectedMode: Int = PrefsTime.timeMode.rawValue
    @State private var manualSunriseDate: Date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: PrefsTime.manualSunrise) ?? Date()
    }()
    @State private var manualSunsetDate: Date = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: PrefsTime.manualSunset) ?? Date()
    }()
    @State private var darkModeOverride: Bool = PrefsTime.darkModeNightOverride
    @State private var sunEventWindow: Int = PrefsTime.sunEventWindow
    @State private var nightShiftStatus: String = ""
    @State private var nightShiftAvailable: Bool = true
    @State private var showLocationSuccess: Bool = false
    @State private var showLocationError: Bool = false
    @State private var locationResultText: String = ""

    // Computed sunrise/sunset for the time bar
    @State private var barSunrise: Date? = nil
    @State private var barSunset: Date? = nil

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let sunEventWindowOptions: [(label: String, value: Int)] = [
        ("1 hour", 3600),
        ("1 hour 30 min", 5400),
        ("2 hours", 7200),
        ("2 hours 30 min", 9000),
        ("3 hours", 10800),
        ("3 hours 30 min", 12600),
        ("4 hours", 14400),
    ]

    private var currentTimeMode: TimeMode {
        TimeMode(rawValue: selectedMode) ?? .disabled
    }

    private var showTimeBar: Bool {
        switch currentTimeMode {
        case .nightShift, .manual, .locationService:
            return barSunrise != nil && barSunset != nil
        default:
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Time")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 8)

                // MARK: - Time Adaptation
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // Location Services
                        radioRow(mode: .locationService, icon: "mappin.and.ellipse", label: "Use Location Services")
                        if currentTimeMode == .locationService {
                            locationSubContent
                        }

                        Divider()

                        // Night Shift
                        radioRow(mode: .nightShift, icon: "house", label: "Use Night Shift", disabled: !nightShiftAvailable)
                        if !nightShiftStatus.isEmpty {
                            Text(nightShiftStatus)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.leading, 36)
                        }

                        Divider()

                        // Manual
                        radioRow(mode: .manual, icon: "clock", label: "Manual")
                        if currentTimeMode == .manual {
                            manualSubContent
                        }

                        Divider()

                        // Light/Dark Mode
                        radioRow(mode: .lightDarkMode, icon: "gear", label: "Light/Dark Mode")

                        Divider()

                        // Disabled
                        radioRow(mode: .disabled, icon: "xmark.circle", label: "Disabled")
                    }
                    .padding(12)
                } label: {
                    Label("Time Adaptation", systemImage: "clock").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Options
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Show only night videos in Dark Mode", isOn: $darkModeOverride)
                            .font(.system(size: 14))
                            .disabled(currentTimeMode == .lightDarkMode)
                            .onChange(of: darkModeOverride) { newValue in
                                PrefsTime.darkModeNightOverride = newValue
                            }

                        HStack {
                            Text("Sunrise/sunset window")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $sunEventWindow) {
                                ForEach(sunEventWindowOptions, id: \.value) { option in
                                    Text(option.label).tag(option.value)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 220, alignment: .trailing)
                            .onChange(of: sunEventWindow) { newValue in
                                PrefsTime.sunEventWindow = newValue
                                refreshTimeBar()
                            }
                        }
                    }
                    .padding(12)
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3").font(Font.title3.bold()).padding(4)
                }

                // MARK: - Time Bar
                if showTimeBar, let sunrise = barSunrise, let sunset = barSunset {
                    GroupBox {
                        TimeBarView(sunrise: sunrise, sunset: sunset, windowSeconds: sunEventWindow)
                            .padding(12)
                    } label: {
                        Label("Day/Night Preview", systemImage: "sun.and.horizon").font(Font.title3.bold()).padding(4)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            setupNightShift()
            refreshTimeBar()
        }
        .onChange(of: selectedMode) { newValue in
            PrefsTime.timeMode = TimeMode(rawValue: newValue) ?? .disabled
            LocationProvider.shared.reevaluate()
            refreshTimeBar()
        }
        .alert("Location Found", isPresented: $showLocationSuccess) {
            Button("OK") {}
        } message: {
            Text(locationResultText)
        }
        .alert("Location Error", isPresented: $showLocationError) {
            Button("OK") {}
        } message: {
            Text(locationResultText)
        }
    }

    // MARK: - Sub-content Views

    private var locationSubContent: some View {
        HStack(spacing: 12) {
            if PrefsTime.cachedLatitude != 0 || PrefsTime.cachedLongitude != 0 {
                let lat = String(format: "%.2f", PrefsTime.cachedLatitude)
                let lon = String(format: "%.2f", PrefsTime.cachedLongitude)
                Text("Cached location: \(lat), \(lon)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Button("Test Location") {
                testLocation()
            }
        }
        .padding(.leading, 36)
    }

    private var manualSubContent: some View {
        HStack(spacing: 16) {
            Text("Sunrise:")
                .font(.system(size: 14))
            DatePicker("", selection: $manualSunriseDate, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: manualSunriseDate) { newValue in
                    PrefsTime.manualSunrise = timeFormatter.string(from: newValue)
                    refreshTimeBar()
                }

            Text("Sunset:")
                .font(.system(size: 14))
            DatePicker("", selection: $manualSunsetDate, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .frame(width: 80)
                .onChange(of: manualSunsetDate) { newValue in
                    PrefsTime.manualSunset = timeFormatter.string(from: newValue)
                    refreshTimeBar()
                }
        }
        .padding(.leading, 36)
    }

    // MARK: - Radio Row

    private func radioRow(mode: TimeMode, icon: String, label: String, disabled: Bool = false) -> some View {
        Button {
            if !disabled {
                selectedMode = mode.rawValue
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedMode == mode.rawValue ? "circle.inset.filled" : "circle")
                    .foregroundColor(selectedMode == mode.rawValue ? .aerial : .secondary)
                    .font(.system(size: 14))
                Image(systemName: icon)
                    .foregroundColor(disabled ? .secondary.opacity(0.5) : .secondary)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(disabled ? .secondary : .primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Actions

    private func setupNightShift() {
        let (isAvailable, sunriseDate, sunsetDate, errorMessage) = NightShift.getInformation()
        if isAvailable, let sunriseDate, let sunsetDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "j:mm:ss", options: 0, locale: Locale.current)
            nightShiftAvailable = true
            nightShiftStatus = "Today's sunrise: " + dateFormatter.string(from: sunriseDate) + "  Today's sunset: " + dateFormatter.string(from: sunsetDate)
        } else {
            NightShift.isNightShiftDataCached = true
            nightShiftAvailable = false
            nightShiftStatus = errorMessage ?? "Night Shift is not available"
        }
    }

    private func testLocation() {
        Locations.sharedInstance.getCoordinates(failure: { error in
            locationResultText = "Make sure you enabled location services on your Mac, and that Aerial is allowed to use your location."
            showLocationError = true
        }, success: { coordinates in
            let lat = String(format: "%.2f", coordinates.latitude)
            let lon = String(format: "%.2f", coordinates.longitude)
            locationResultText = "Aerial can access your location (latitude: \(lat), longitude: \(lon)) and will use it to show you the correct videos."
            showLocationSuccess = true
            refreshTimeBar()
        })
    }

    private func refreshTimeBar() {
        switch currentTimeMode {
        case .locationService:
            _ = TimeManagement.sharedInstance.calculateFromCoordinates()
            let (sunrise, sunset) = TimeManagement.sharedInstance.getSunriseSunset()
            barSunrise = sunrise
            barSunset = sunset
        case .nightShift, .manual:
            let (sunrise, sunset) = TimeManagement.sharedInstance.getSunriseSunset()
            barSunrise = sunrise
            barSunset = sunset
        default:
            barSunrise = nil
            barSunset = nil
        }
    }
}

// MARK: - Time Bar View

struct TimeBarView: View {
    let sunrise: Date
    let sunset: Date
    let windowSeconds: Int

    private let barHeight: CGFloat = 32

    private var segments: [(label: String, fraction: CGFloat, color: Color)] {
        let cal = Calendar.current
        let sunriseMin = CGFloat(cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise))
        let sunsetMin = CGFloat(cal.component(.hour, from: sunset) * 60 + cal.component(.minute, from: sunset))
        let windowMin = CGFloat(windowSeconds) / 60.0
        let total: CGFloat = 1440.0

        let night1 = max(sunriseMin, 0)
        let sunriseWindow = min(windowMin, sunsetMin - sunriseMin)
        let dayStart = sunriseMin + sunriseWindow
        let dayEnd = max(sunsetMin - windowMin, dayStart)
        let day = dayEnd - dayStart
        let sunsetWindow = min(windowMin, total - dayEnd)
        let night2 = max(total - sunsetMin, 0)

        return [
            ("", night1 / total, Color.gray),
            ("", sunriseWindow / total, Color.purple),
            ("", day / total, Color.teal),
            ("", sunsetWindow / total, Color.orange),
            ("", night2 / total, Color.gray),
        ]
    }

    private var timeLabels: [(time: String, fraction: CGFloat)] {
        let cal = Calendar.current
        let sunriseMin = CGFloat(cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise))
        let sunsetMin = CGFloat(cal.component(.hour, from: sunset) * 60 + cal.component(.minute, from: sunset))
        let windowMin = CGFloat(windowSeconds) / 60.0
        let total: CGFloat = 1440.0

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let eSunrise = sunrise.addingTimeInterval(TimeInterval(windowSeconds))
        let pSunset = sunset.addingTimeInterval(TimeInterval(-windowSeconds))

        return [
            (formatter.string(from: sunrise), sunriseMin / total),
            (formatter.string(from: eSunrise), (sunriseMin + windowMin) / total),
            (formatter.string(from: pSunset), (sunsetMin - windowMin) / total),
            (formatter.string(from: sunset), sunsetMin / total),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Legend
            HStack(spacing: 16) {
                legendItem(color: .gray, label: "Night")
                legendItem(color: .purple, label: "Sunrise")
                legendItem(color: .teal, label: "Day")
                legendItem(color: .orange, label: "Sunset")
            }
            .font(.system(size: 11))

            // Bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.fraction > 0 {
                            RoundedRectangle(cornerRadius: 0)
                                .fill(segment.color)
                                .frame(width: max(segment.fraction * geo.size.width, 1))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: barHeight)

            // Time labels
            GeometryReader { geo in
                let totalWidth = geo.size.width
                ForEach(Array(timeLabels.enumerated()), id: \.offset) { _, item in
                    Text(item.time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .position(x: item.fraction * totalWidth, y: 8)
                }
            }
            .frame(height: 20)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

struct TimeSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        TimeSettingsPanel()
            .frame(width: 500, height: 800)
    }
}
