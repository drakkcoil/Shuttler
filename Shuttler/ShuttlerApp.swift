//
//  ShuttlerApp.swift
//  Shuttler
//
//  Created by Adam Newman on 12/12/25.
//

import SwiftUI

@main
struct ShuttlerApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: ShuttlerDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
