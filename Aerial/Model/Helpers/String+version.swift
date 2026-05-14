//
//  String+version.swift
//  AerialUpdater
//
//  Created by Guillaume Louel on 03/08/2020.
//

import Foundation

extension String {
    func capitalizeFirstLetter() -> String {
        return self.prefix(1).capitalized + dropFirst()
    }


}
