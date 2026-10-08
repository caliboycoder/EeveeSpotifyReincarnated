import SwiftUI
import UIKit

struct EeveeMiscellaneousSettingsView: View {
    @State private var blockTelemetry = UserDefaults.blockTelemetry
    @State private var cleanShareLinks = UserDefaults.cleanShareLinks
    @State private var blockRatingPrompts = UserDefaults.blockRatingPrompts
    @State private var downloadManagerEnabled = UserDefaults.downloadOptions.enabled

    var body: some View {
        List {
            Section(footer: Text("block_telemetry_footer".localized)) {
                Toggle("block_telemetry".localized, isOn: $blockTelemetry)
            }

            Section(footer: Text("block_rating_prompts_footer".localized)) {
                Toggle("block_rating_prompts".localized, isOn: $blockRatingPrompts)
            }

            Section(footer: Text("clean_share_links_description".localized)) {
                Toggle("clean_share_links".localized, isOn: $cleanShareLinks)
            }

            Section(footer: Text("download_manager_footer".localized)) {
                Toggle("download_manager".localized, isOn: $downloadManagerEnabled)
            }

            RestartSection(visible:
                blockTelemetry != TelemetryBlock.launchEnabled
                || blockRatingPrompts != RatingPromptBlock.launchEnabled
                || downloadManagerEnabled != DownloadFeature.launchEnabled
            )

            SpacerView()
        }
        .eeveeSettingsStyle()
        .onChange(of: blockTelemetry) { UserDefaults.blockTelemetry = $0 }
        .onChange(of: cleanShareLinks) { UserDefaults.cleanShareLinks = $0 }
        .onChange(of: blockRatingPrompts) { UserDefaults.blockRatingPrompts = $0 }
        .onChange(of: downloadManagerEnabled) { newValue in
            // Read-modify-write so the other download options are preserved.
            var options = UserDefaults.downloadOptions
            options.enabled = newValue
            UserDefaults.downloadOptions = options
        }
    }
}
