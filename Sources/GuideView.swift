import AppKit
import SwiftUI

enum GuideCommands {
    static let install = #"""
    mkdir -p "$HOME/trusttunnel"
    curl -fsSL \
      https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh \
      -o "$HOME/trusttunnel/install-client.sh"
    sh "$HOME/trusttunnel/install-client.sh" -o "$HOME/trusttunnel"
    "$HOME/trusttunnel/trusttunnel_client" --version
    """#

    static let configure = #"""
    cd "$HOME/trusttunnel"
    test ! -e trusttunnel_client.toml &&
    ./setup_wizard --mode non-interactive \
      --endpoint_config endpoint.toml \
      --settings trusttunnel_client.toml &&
    chmod 600 endpoint.toml trusttunnel_client.toml
    """#

    static let wizard = #"""
    cd "$HOME/trusttunnel"
    ./setup_wizard
    """#

    static let checkFiles = #"""
    cd "$HOME/trusttunnel"
    ./trusttunnel_client --version
    ls -l trusttunnel_client.toml
    """#
}

struct GuideView: View {
    @ObservedObject var model: TunnelModel
    let reload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("guide.title")).font(.largeTitle.bold())
                    Text(L("guide.intro")).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L(model.loaded && model.binaryAvailable ? "guide.ready" : "guide.notReady"),
                              systemImage: model.loaded && model.binaryAvailable ? "checkmark.circle" : "wrench.and.screwdriver")
                            .font(.headline)
                        Text(model.directory).font(.caption.monospaced()).textSelection(.enabled)
                        if !model.loaded || !model.binaryAvailable {
                            Text(L("guide.missingFiles")).font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(L("guide.settings")) { model.section = "app" }
                            Button(L("Перечитать"), action: reload).disabled(model.busy)
                            if model.loaded && model.binaryAvailable {
                                Button(L("guide.connection")) { model.section = "connection" }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                card("guide.requirements.title") {
                    paragraph("guide.requirements.body")
                    officialLink("guide.serverLink", "https://github.com/TrustTunnel/TrustTunnel#endpoint-setup")
                }
                card("guide.install.title") {
                    paragraph("guide.install.body")
                    CommandBlock(command: GuideCommands.install)
                    paragraph("guide.install.existing")
                    officialLink("guide.cliLink", "https://github.com/TrustTunnel/TrustTunnelClient")
                    officialLink("guide.installLink", "https://github.com/TrustTunnel/TrustTunnel#install-the-client")
                    officialLink("guide.releasesLink", "https://github.com/TrustTunnel/TrustTunnelClient/releases")
                }
                card("guide.configure.title") {
                    paragraph("guide.configure.body")
                    CommandBlock(command: GuideCommands.configure)
                    paragraph("guide.configure.existing")
                    DisclosureGroup(L("guide.configure.manualTitle")) {
                        paragraph("guide.configure.manualBody").padding(.top, 8)
                        CommandBlock(command: GuideCommands.wizard)
                    }
                    officialLink("guide.configLink", "https://github.com/TrustTunnel/TrustTunnelClient/blob/master/trusttunnel/README.md")
                }
                card("guide.connect.title") {
                    paragraph("guide.connect.body")
                    paragraph("guide.connect.permissions")
                }
                card("guide.verify.title") {
                    paragraph("guide.verify.body")
                }
                card("guide.routing.title") {
                    paragraph("guide.routing.body")
                }
                card("guide.dns.title") {
                    paragraph("guide.dns.body")
                    CommandBlock(command: "https://cloudflare-dns.com/dns-query")
                    officialLink("guide.dnsLink", "https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/")
                }
                card("guide.daily.title") {
                    paragraph("guide.daily.body")
                }
                card("guide.troubleshooting.title") {
                    issue("guide.issue.missing.title", "guide.issue.missing.body")
                    CommandBlock(command: GuideCommands.checkFiles)
                    issue("guide.issue.folder.title", "guide.issue.folder.body")
                    issue("guide.issue.external.title", "guide.issue.external.body")
                    issue("guide.issue.auth.title", "guide.issue.auth.body")
                    issue("guide.issue.tls.title", "guide.issue.tls.body")
                    issue("guide.issue.network.title", "guide.issue.network.body")
                    issue("guide.issue.config.title", "guide.issue.config.body")
                    issue("guide.issue.python.title", "guide.issue.python.body")
                    issue("guide.issue.gatekeeper.title", "guide.issue.gatekeeper.body")
                    officialLink("guide.appleLink", "https://support.apple.com/en-us/102445")
                }
                card("guide.backup.title") {
                    paragraph("guide.backup.body")
                    officialLink("guide.verifyReleaseLink", "https://github.com/TrustTunnel/TrustTunnelClient/blob/master/VERIFY_RELEASES.md")
                }
            }.padding(24).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(title)).font(.title3.bold())
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ key: String) -> some View {
        Text(L(key)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func issue(_ title: String, _ body: String) -> some View {
        DisclosureGroup(L(title)) { paragraph(body).padding(.vertical, 8) }
    }

    private func officialLink(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            Label(L(title), systemImage: "arrow.up.right.square")
        }
    }
}

private struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("guide.copyHint")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                } label: {
                    Label(L(copied ? "Скопировано" : "Скопировать"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.borderless)
            }
            ScrollView(.horizontal) {
                Text(verbatim: command).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }
        }.padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
