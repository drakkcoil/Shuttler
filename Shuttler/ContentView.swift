//
//  ContentView.swift
//  Shuttler
//
//  Created by Adam Newman on 12/12/25.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: ShuttlerDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(ShuttlerDocument()))
}
