import DesignSystem
import Domain
import SwiftUI
import ThemeEngine
#if os(iOS)
import UIKit
#endif

/// 统一搜索：歌曲 / 专辑 / 艺术家 / 歌单分类结果 + 搜索历史。
/// 全部基于本地持久化资料库，离线可用；服务器在线搜索在后续阶段接入。
struct SearchView: View {
    @ObservedObject var model: AuralisAppModel
    let theme: BuiltInTheme
    @State private var query = ""
    /// 防抖后的查询词：输入停顿约 150ms 后才真正过滤，避免大资料库逐键全量扫描。
    @State private var debouncedQuery = ""

    private func matches(_ text: String, needle: String) -> Bool {
        text.localizedLowercase.contains(needle)
    }

    private var needle: String { debouncedQuery.localizedLowercase.trimmingCharacters(in: .whitespaces) }

    private var songResults: [Track] {
        guard !needle.isEmpty else { return [] }
        return model.catalog.tracks.filter {
            matches($0.title, needle: needle)
                || matches($0.artistName, needle: needle)
                || matches($0.albumTitle, needle: needle)
        }
    }

    private var albumResults: [Album] {
        guard !needle.isEmpty else { return [] }
        return model.catalog.albums.filter {
            matches($0.title, needle: needle) || matches($0.artistName, needle: needle)
        }
    }

    private var artistResults: [Artist] {
        guard !needle.isEmpty else { return [] }
        return model.catalog.artists.filter { matches($0.name, needle: needle) }
    }

    private var playlistResults: [Playlist] {
        guard !needle.isEmpty else { return [] }
        return model.catalog.playlists.filter { matches($0.name, needle: needle) }
    }

    private var hasAnyResults: Bool {
        !songResults.isEmpty || !albumResults.isEmpty || !artistResults.isEmpty || !playlistResults.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.colorTokens.background.color)
        .task(id: query) {
            // 防抖：输入停顿后再更新实际过滤词；清空立即生效。
            guard !query.isEmpty else {
                debouncedQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
    }

    private var searchField: some View {
        HStack(spacing: AuralisSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colorTokens.secondaryText.color)
            TextField("歌曲、专辑、艺术家或歌单", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit {
                    model.recordSearch(query)
                    dismissSearchKeyboard()
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    debouncedQuery = ""
                    dismissSearchKeyboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(theme.colorTokens.secondaryText.color)
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(AuralisSpacing.medium)
        .background(theme.colorTokens.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: AuralisSpacing.medium))
        .padding(.horizontal, AuralisSpacing.large)
        .padding(.top, AuralisSpacing.large)
        .padding(.bottom, AuralisSpacing.small)
    }

    @ViewBuilder
    private var content: some View {
        if query.isEmpty {
            recentSearches
        } else if !hasAnyResults {
            if model.isServerSearching {
                ProgressView("正在服务器搜索…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.serverSearchResults.isEmpty {
                VStack(spacing: AuralisSpacing.medium) {
                    AuralisEmptyState(
                        icon: "music.note.list",
                        title: "本地没有匹配结果",
                        message: "本地持久化资料库中没有同时匹配歌曲、专辑、艺术家或歌单的内容。可以尝试在服务器上在线搜索。",
                        actionTitle: "清除搜索",
                        colors: theme.colorTokens
                    ) { query = "" }
                    Button {
                        model.searchOnServer(query)
                    } label: {
                        Label("在线搜索服务器", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(HapticBorderedButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultList
            }
        } else {
            resultList
        }
    }

    /// 搜索历史：点击回填、可一键清空。
    @ViewBuilder
    private var recentSearches: some View {
        if model.recentSearches.isEmpty {
            AuralisEmptyState(
                icon: "magnifyingglass",
                title: "搜索你的音乐库",
                message: "输入歌曲、专辑、艺术家或歌单名称，澜音会在本地持久化资料库中匹配（离线可用）。",
                colors: theme.colorTokens
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AuralisSpacing.medium) {
                    HStack {
                        Text("最近搜索").font(.headline)
                        Spacer()
                        Button("清除") { model.clearSearchHistory() }
                            .font(.caption)
                            .buttonStyle(HapticPlainButtonStyle())
                            .accessibilityLabel("清除搜索历史")
                    }
                    .padding(.horizontal, AuralisSpacing.large)
                    .padding(.top, AuralisSpacing.medium)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AuralisSpacing.small)], alignment: .leading, spacing: AuralisSpacing.small) {
                        ForEach(model.recentSearches, id: \.self) { term in
                            Button {
                                query = term
                                debouncedQuery = term
                                model.recordSearch(term)
                            } label: {
                                Label(term, systemImage: "clock")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(HapticBorderedButtonStyle())
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, AuralisSpacing.large)
                }
            }
        }
    }

    private var resultList: some View {
        List {
            if !model.serverSearchResults.isEmpty {
                Section("服务器在线结果") {
                    ForEach(model.serverSearchResults) { track in
                        TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.recordSearch(query)
                                model.selectAndPlay(track)
                            }
                    }
                }
            }
            if !songResults.isEmpty {
                Section("歌曲") {
                    ForEach(songResults) { track in
                        TrackRow(track: track, isCurrent: track.id == model.currentTrack.id, theme: theme)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.recordSearch(query)
                                model.selectAndPlay(track)
                            }
                    }
                }
            }
            if !albumResults.isEmpty {
                Section("专辑") {
                    ForEach(albumResults) { album in
                        Button {
                            model.recordSearch(query)
                            model.browseDestination = .album(album)
                        } label: {
                            HStack(spacing: AuralisSpacing.medium) {
                                ArtworkView(title: album.title, artworkKey: album.artworkKey, colors: theme.colorTokens, size: 40, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).font(.body).foregroundStyle(theme.colorTokens.primaryText.color).lineLimit(1)
                                    Text(album.artistName).font(.caption).foregroundStyle(theme.colorTokens.secondaryText.color).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                    }
                }
            }
            if !artistResults.isEmpty {
                Section("艺术家") {
                    ForEach(artistResults) { artist in
                        Button {
                            model.recordSearch(query)
                            model.browseDestination = .artist(artist)
                        } label: {
                            HStack(spacing: AuralisSpacing.medium) {
                                Image(systemName: "person.crop.square")
                                    .font(.title3)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                                Text(artist.name)
                                    .foregroundStyle(theme.colorTokens.primaryText.color)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(theme.colorTokens.secondaryText.color)
                            }
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                    }
                }
            }
            if !playlistResults.isEmpty {
                Section("歌单") {
                    ForEach(playlistResults) { playlist in
                        Button {
                            model.recordSearch(query)
                            model.browseDestination = .playlist(playlist)
                        } label: {
                            HStack(spacing: AuralisSpacing.medium) {
                                Image(systemName: "music.note.list")
                                    .font(.title3)
                                    .foregroundStyle(theme.colorTokens.secondaryText.color)
                                Text(playlist.name)
                                    .foregroundStyle(theme.colorTokens.primaryText.color)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func dismissSearchKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

