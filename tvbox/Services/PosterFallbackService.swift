import Foundation

/// 当源海报（常见是豆瓣图片）无法访问时，按片名从 TMDB / Bangumi 查找替代海报。
actor PosterFallbackService {
    static let shared = PosterFallbackService()

    /// 用户提供的 TMDB v3 API Key。
    private static let defaultTMDBAPIKey = "964ed0363ec42cfbb63543bc1336b9db"
    private static let tmdbImageBase = "https://image.tmdb.org/t/p/w500"
    private static let bangumiSearchURL = "https://api.bgm.tv/v0/search/subjects"

    private let session: URLSession
    private var hits: [String: URL] = [:]
    private var misses: Set<String> = []
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    private var tmdbAPIKey: String {
        let saved = UserDefaults.standard
            .string(forKey: "tmdb_api_key")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Self.defaultTMDBAPIKey : saved
    }

    func posterURL(title: String, year: String?) async -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Self.cacheKey(title: trimmed, year: year)
        if let hit = hits[key] { return hit }
        if misses.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await resolve(title: trimmed, year: year) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            hits[key] = result
        } else {
            misses.insert(key)
        }
        return result
    }

    private func resolve(title: String, year: String?) async -> URL? {
        if let tmdb = await searchTMDB(title: title, year: year) {
            return tmdb
        }
        return await searchBangumi(title: title, year: year)
    }

    // MARK: - TMDB

    private struct Candidate {
        let names: [String]
        let year: String?
        let posterURL: URL?
    }

    private func searchTMDB(title: String, year: String?) async -> URL? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: tmdbAPIKey),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "query", value: title)
        ]
        guard let url = components?.url,
              let json = await getJSON(url: url),
              let root = json as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            return nil
        }

        let candidates: [Candidate] = results.compactMap { item in
            guard let posterPath = item["poster_path"] as? String,
                  !posterPath.isEmpty else { return nil }
            let names = [
                item["title"] as? String,
                item["name"] as? String,
                item["original_title"] as? String,
                item["original_name"] as? String
            ].compactMap { $0 }
            let date = (item["release_date"] as? String) ?? (item["first_air_date"] as? String)
            return Candidate(
                names: names,
                year: date.flatMap(Self.yearPrefix),
                posterURL: URL(string: Self.tmdbImageBase + posterPath)
            )
        }
        return bestCandidate(from: candidates, title: title, year: year)?.posterURL
    }

    // MARK: - Bangumi

    private func searchBangumi(title: String, year: String?) async -> URL? {
        guard let url = URL(string: Self.bangumiSearchURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TVBox-macOS/1.0 (private)", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "keyword": title,
            "filter": ["type": [2, 4, 6]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let json = await getJSON(request: request),
              let root = json as? [String: Any],
              let results = root["data"] as? [[String: Any]] else {
            return nil
        }

        let candidates: [Candidate] = results.compactMap { item in
            let images = item["images"] as? [String: Any]
            guard let large = images?["large"] as? String,
                  let poster = Self.httpsURL(large) else { return nil }
            let names = [
                item["name"] as? String,
                item["name_cn"] as? String
            ].compactMap { $0 }
            return Candidate(
                names: names,
                year: (item["date"] as? String).flatMap(Self.yearPrefix),
                posterURL: poster
            )
        }
        return bestCandidate(from: candidates, title: title, year: year)?.posterURL
    }

    // MARK: - Scoring

    private func bestCandidate(from candidates: [Candidate], title: String, year: String?) -> Candidate? {
        let target = Self.normalize(title)
        guard !target.isEmpty else { return nil }
        var best: (candidate: Candidate, score: Int)?
        for candidate in candidates {
            let names = candidate.names.map(Self.normalize).filter { !$0.isEmpty }
            guard let nameScore = names.map({ name -> Int in
                if name == target { return 100 }
                if name.contains(target) || target.contains(name) { return 40 }
                return 0
            }).max(), nameScore > 0 else { continue }

            var score = nameScore
            if let year, let candidateYear = candidate.year {
                score += candidateYear == year ? 50 : -30
            } else if year != nil {
                score += 5
            }
            if score >= 40, score > (best?.score ?? Int.min) {
                best = (candidate, score)
            }
        }
        return best?.candidate
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private static func yearPrefix(_ date: String) -> String? {
        let year = date.prefix(4)
        return year.count == 4 && Int(year) != nil ? String(year) : nil
    }

    private static func httpsURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }
        if trimmed.hasPrefix("http://") {
            return URL(string: "https://" + trimmed.dropFirst("http://".count))
        }
        return URL(string: trimmed)
    }

    private static func cacheKey(title: String, year: String?) -> String {
        "\(normalize(title))|\(year ?? "")"
    }

    // MARK: - Networking

    private func getJSON(url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await getJSON(request: request)
    }

    private func getJSON(request: URLRequest) async -> Any? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
    }
}
