/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MainAppView.swift
//
// Central navigation hub that displays different views based on DAT SDK registration and device states.
// When unregistered, shows the registration flow. When registered, shows the device selection screen
// for choosing which Meta wearable device to stream from.
//

import MWDATCore
import SwiftUI

struct MainAppView: View {
  let wearables: WearablesInterface
  var viewModel: WearablesViewModel
  @State private var tab = 0

  var body: some View {
    TabView(selection: $tab) {
      AutoScanView(wearablesVM: viewModel).tabItem { Label("Auto Scan", systemImage: "viewfinder") }.tag(0)
      Group {
        if viewModel.registrationState == .registered {
          CameraView(wearables: wearables, wearablesVM: viewModel)
        } else {
          HomeScreenView(viewModel: viewModel)
        }
      }.tabItem { Label("Glasses", systemImage: "eyeglasses") }.tag(1)
      SolutionHistoryView().tabItem { Label("PDFs", systemImage: "doc.richtext") }.tag(2)
    }
    // The Start Glasses Scan shortcut always lands on Auto Scan, which starts the camera once the app is active.
    .onChange(of: AutoScanModel.shared.shortcutRequests) { _, _ in tab = 0 }
  }
}
