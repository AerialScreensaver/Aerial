//
//  Forecast.swift
//  Aerial
//
//  Created by Guillaume Louel on 26/04/2021.
//  Copyright © 2021 Guillaume Louel. All rights reserved.
//
// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let forecast = try? newJSONDecoder().decode(Forecast.self, from: jsonData)

import Foundation
internal import _LocationEssentials

// MARK: - Forecast
struct ForecastElement: Codable {
    let cod: String?
    let message, cnt: Int?
    let list: [FList]?
    let city: City?
}

// MARK: - City
struct City: Codable {
    let id: Int?
    let name: String?
    let coord: Coord?
    let country: String?
    let population, timezone, sunrise, sunset: Int?
}

// MARK: - Coord
struct Coord: Codable {
    let lat, lon: Double?
}

// MARK: - List
struct FList: Codable {
    let dt: Int?
    let main: MainClass?
    let weather: [OWWeather]?
    let clouds: Clouds?
    let wind: Wind?
    let visibility: Int?
    let pop: Double?
    let sys: Sys?
    let dtTxt: String?
    let rain: Rain?

    enum CodingKeys: String, CodingKey {
        case dt, main, weather, clouds, wind, visibility, pop, sys
        case dtTxt = "dt_txt"
        case rain
    }
}

// MARK: - Clouds
struct Clouds: Codable {
    let all: Int?
}

// MARK: - MainClass
struct MainClass: Codable {
    let temp, feelsLike, tempMin, tempMax: Double?
    let pressure, seaLevel, grndLevel, humidity: Int?
    let tempKf: Double?

    enum CodingKeys: String, CodingKey {
        case temp
        case feelsLike = "feels_like"
        case tempMin = "temp_min"
        case tempMax = "temp_max"
        case pressure
        case seaLevel = "sea_level"
        case grndLevel = "grnd_level"
        case humidity
        case tempKf = "temp_kf"
    }
}

// MARK: - Rain
struct Rain: Codable {
    let the3H: Double?

    enum CodingKeys: String, CodingKey {
        case the3H = "3h"
    }
}

// MARK: - Sys
struct Sys: Codable {
    let pod: String?
}

// MARK: - ForecastError
struct ForecastError: Codable {
    let cod, message: String?
}

// MARK: - Wind
struct Wind: Codable {
    let speed: Double?
    let deg: Int?
    let gust: Double?
}

struct Forecast {

    static func getShortcodeLanguage() -> String {
        // Those are the languages supported by OpenWeather
        let weatherLanguages = ["af", "al", "ar", "az", "bg", "ca", "cz", "da", "de", "el", "en",
                                "eu", "fa", "fi", "fr", "gl", "he", "hi", "hr", "hu", "id", "it",
                                "ja", "kr", "la", "lt", "mk", "no", "nl", "pl", "pt", "pt_br", "ro",
                                "ru", "sv", "sk", "sl", "es", "sr", "th", "tr", "uk", "vi", "zh_cn",
                                "zh_tw", "zu" ]

        if PrefsAdvanced.ciOverrideLanguage == "" {
            let bestMatchedLanguage = Bundle.preferredLocalizations(from: weatherLanguages, forPreferences: Locale.preferredLanguages).first
            if let match = bestMatchedLanguage {
                debugLog("Best matched language : \(match)")
                return match
            }
        } else {
            debugLog("Overrode matched language : \(PrefsAdvanced.ciOverrideLanguage)")
            return PrefsAdvanced.ciOverrideLanguage
        }

        // We fallback here if nothing works
        return "en"
    }

    // MARK: - Fetch (always metric)

    static func fetch(location: WeatherLocationSource,
                      completion: @escaping (Result<ForecastElement, NetworkError>) -> Void) {
        let urlString: String
        switch location {
        case .coordinates(let lat, let lon):
            let latStr = String(format: "%.2f", lat)
            let lonStr = String(format: "%.2f", lon)
            urlString = "https://api.openweathermap.org/data/2.5/forecast"
                + "?lat=\(latStr)&lon=\(lonStr)"
                + "&units=metric"
                + "&lang=\(getShortcodeLanguage())"
                + "&APPID=\(APISecrets.openWeatherAppId)"
        case .city(let name):
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            urlString = "https://api.openweathermap.org/data/2.5/forecast"
                + "?q=\(encoded)"
                + "&units=metric"
                + "&lang=\(getShortcodeLanguage())"
                + "&APPID=\(APISecrets.openWeatherAppId)"
        }

        fetchData(from: urlString) { result in
            switch result {
            case .success(let jsonString):
                let jsonData = jsonString.data(using: .utf8)!
                if let forecast = try? newJSONDecoder().decode(ForecastElement.self, from: jsonData) {
                    completion(.success(forecast))
                } else if (try? newJSONDecoder().decode(ForecastError.self, from: jsonData)) != nil {
                    completion(.failure(.cityNotFound))
                } else {
                    completion(.failure(.unknown))
                }
            case .failure:
                completion(.failure(.unknown))
            }
        }
    }

    private static func fetchData(from urlString: String, completion: @escaping (Result<String, NetworkError>) -> Void) {
        // check the URL is OK, otherwise return with a failure
        guard let url = URL(string: urlString) else {
            completion(.failure(.badURL))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            // the task has completed – push our work back to the main thread
            DispatchQueue.main.async {
                if let data = data {
                    // success: convert the data to a string and send it back
                    let stringData = String(decoding: data, as: UTF8.self)
                    completion(.success(stringData))
                } else if error != nil {
                    // any sort of network failure
                    completion(.failure(.requestFailed))
                } else {
                    // this ought not to be possible, yet here we are
                    completion(.failure(.unknown))
                }
            }
        }.resume()
    }
}
