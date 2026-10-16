import MapKit
import SwiftUI
import V2MacCore

/// The connection on a globe of our own: you, the server, and requests leaving the server as arcs
/// through the sky. MapKit draws a globe only with aerial pictures, and its plain map stays flat.
struct ConnectionMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// False while the window is in the background: nothing moves then.
    @Environment(\.appearsActive) private var appearsActive
    @State private var camera = GlobeCamera(latitude: 35, longitude: 30, distance: 24_000_000)
    @State private var dragStart: GlobeCamera?
    @State private var zoomStart: GlobeCamera?
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    @State private var user: MapPlace?
    @State private var server: MapPlace?
    /// When each country's arc first appeared, so it travels out once and then stays.
    @State private var arcStarts: [String: Date] = [:]
    @State private var geo = GeoIPIndex()

    private var isLive: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugDemoData") { return true }
        #endif
        return model.connection.phase == .connected
    }

    /// "Tehran", from the time zone: no location permission and no request outside the tunnel.
    private static let userCity = TimeZone.current.identifier
        .split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""

    /// The exit's city when the check found it, else the city and flag in the server's name.
    private var serverPlace: String? {
        let english = Locale(identifier: "en")
        if case .known(let info) = model.connection.exit, let place = info.place(locale: english) { return place }
        guard let active = model.connection.activeServer else { return nil }
        let name = ServerName(active.name)
        let city = name.title.trimmingCharacters(in: .decimalDigits.union(.whitespaces).union(.punctuationCharacters))
        let country = name.flag.flatMap(Self.regionCode).flatMap { english.localizedString(forRegionCode: $0) }
        let parts = [city, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var serverTitle: String {
        model.connection.activeServer.map { ServerName($0.name).title } ?? String(localized: "No Server")
    }

    var body: some View {
        let live = isLive
        let animate = live && !reduceMotion && appearsActive
        let dark = colorScheme == .dark
        let flag = model.connection.activeServer.flatMap { ServerName($0.name).flag }
        // "🇩🇪 Frankfurt" over "Germany".
        let serverTag = server.map {
            MapTag(title: [flag, $0.city ?? $0.country].compactMap { $0 }.joined(separator: " "), subtitle: $0.city == nil ? nil : $0.country)
        }
        let requests = arcs(live: live)
        let hosts = Set(requests.map(\.host)).sorted()
        GeometryReader { geo in
            // Under the toolbar and the bar alike, with the globe in the middle of the room they leave.
            let insets = geo.safeAreaInsets
            let middle = CGPoint(x: (geo.size.width + insets.leading - insets.trailing) / 2,
                                 y: (geo.size.height + insets.top - insets.bottom) / 2)
            let camera = camera
            ZStack {
                // Drawn again only when the camera moves; the moving parts are a layer of their own.
                GlobeLayer(camera: camera, middle: middle, dark: dark).equatable()
                // 30 frames a second is smooth for this motion at half the work of 60.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { timeline in
                    let scene = MapScene(camera: camera, middle: middle, user: user?.coordinate, server: server?.coordinate,
                                         requests: requests, live: live, animate: animate)
                    Canvas { context, size in
                        scene.draw(in: &context, size: size, at: timeline.date)
                    } symbols: {
                        // Laid out once and only placed on each frame: text laid out per frame was
                        // most of the cost of drawing.
                        MapTag(title: String(localized: "You")).tag(MapSymbol.you)
                        if let serverTag { serverTag.tag(MapSymbol.server) }
                        ChainBadge(color: live ? MapScene.link : .gray).tag(MapSymbol.chain)
                        ForEach(hosts, id: \.self) { MapTag(title: $0, small: true).tag(MapSymbol.host($0)) }
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .gesture(rotate(globeRadius: GlobeProjection(camera: camera, size: geo.size, middle: middle).rim.radius))
            .simultaneousGesture(zoom)
        }
        .ignoresSafeArea()
        .background(dark ? Color(red: 0.03, green: 0.05, blue: 0.09) : Color(red: 0.93, green: 0.95, blue: 0.97))
        .onContinuousHover { phase in
            if case .active = phase { isHovering = true } else { isHovering = false }
        }
        .onAppear {
            // Scrolling zooms, as in Maps. SwiftUI has no scroll wheel gesture.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
                let handled = MainActor.assumeIsolated {
                    guard isHovering else { return false }
                    camera.zoom(by: exp(delta))
                    return true
                }
                return handled ? nil : event
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }
        .overlay(alignment: .bottomLeading) {
            RouteCard(user: user, server: server, serverTitle: serverTitle, flag: flag, live: live)
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            let recent = Array(model.connection.watcher.connections.suffix(6).reversed())
            if live, !recent.isEmpty {
                RequestFeed(connections: recent).padding(16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TopApps(connections: model.connection.watcher.connections).padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection map")
        .task(id: serverPlace) {
            if user == nil { user = await Self.locate(Self.userCity) }
            guard let serverPlace else { server = nil; return }
            // A city that is not a place ("VIP 3") falls back to its country.
            server = await Self.locate(serverPlace)
            if server == nil, let country = serverPlace.split(separator: ", ").last { server = await Self.locate(String(country)) }
            if let u = user?.coordinate, let s = server?.coordinate {
                camera.latitude = (u.latitude + s.latitude) / 2
                camera.longitude = (u.longitude + s.longitude) / 2
            }
        }
        .task {
            guard geo.isEmpty else { return }
            let file = AppPaths.assetsDirectory.appendingPathComponent("geoip.dat")
            geo = await Task.detached { GeoIPIndex(contentsOf: file) }.value
        }
    }

    /// One arc per country for every open connection that has moved data: placed by its address
    /// (the core's own geoip.dat) when known, else by the site's country ending. Nothing is asked
    /// outside the Mac.
    private func arcs(live: Bool) -> [MapRequest] {
        guard live else { return [] }
        let active = model.connection.watcher.connections.filter { $0.isOpen && $0.sent + $0.received > 0 }
        let byCountry = Dictionary(grouping: active) { c in
            c.remoteAddress.flatMap(geo.country(of:)) ?? Self.countryCode(of: c.host)
        }
        return byCountry.compactMap { code, list -> MapRequest? in
            guard let code, let place = Self.countries[code] else { return nil }
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            let start = arcStarts[code] ?? .now
            if arcStarts[code] == nil { Task { @MainActor in arcStarts[code] = start } }
            return MapRequest(id: code, host: "\(Self.flag(code)) \(name) · \(list.count)", flag: Self.flag(code),
                              coordinate: .init(latitude: place.latitude, longitude: place.longitude), start: start)
        }
        .sorted { $0.id < $1.id }
    }

    /// A point in each country, from the system's time zone table.
    private static let countries = CountryPlaces.read((try? String(contentsOf: CountryPlaces.systemFile, encoding: .utf8)) ?? "")

    /// Two-letter endings used by sites anywhere, not by their country.
    private static let globalEndings: Set<String> = ["io", "co", "ai", "me", "tv", "fm", "ly", "to", "cc", "gg", "so", "sh", "ws", "la", "eu"]

    /// The country of a host's domain ending: `bbc.co.uk` → GB.
    static func countryCode(of host: String) -> String? {
        guard let ending = host.lowercased().split(separator: ".").last, ending.count == 2, !globalEndings.contains(String(ending)) else { return nil }
        let code = ending == "uk" ? "GB" : ending.uppercased()
        return Locale.Region.isoRegions.contains(Locale.Region(code)) ? code : nil
    }

    static func flag(_ code: String) -> String {
        String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 65 + $0.value) }))
    }

    /// Dragging turns the globe: a drag across its radius turns it by about a radian.
    private func rotate(globeRadius: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? camera
                dragStart = start
                let degrees = 180 / .pi / max(globeRadius, 1)
                camera.latitude = min(max(start.latitude + drag.translation.height * degrees, -80), 80)
                camera.longitude = start.longitude - drag.translation.width * degrees
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { pinch in
                let start = zoomStart ?? camera
                zoomStart = start
                camera.distance = start.distance
                camera.zoom(by: pinch.magnification)
            }
            .onEnded { _ in zoomStart = nil }
    }

    @MainActor private static var places: [String: MapPlace] = [:]

    /// Names come from the geocoder, so "VIP 3, Germany" shows as just "Germany".
    private static func locate(_ query: String) async -> MapPlace? {
        if let known = places[query] { return known }
        guard !query.isEmpty, let request = MKGeocodingRequest(addressString: query),
              let item = try? await request.mapItems.first else { return nil }
        let names = item.addressRepresentations
        let found = MapPlace(coordinate: item.location.coordinate, city: names?.cityName, country: names?.regionName)
        places[query] = found
        return found
    }

    /// "🇩🇪" → "DE".
    private static func regionCode(fromFlag flag: String) -> String? {
        let letters = flag.unicodeScalars.compactMap { Unicode.Scalar($0.value - 0x1F1E6 + 65) }.map(Character.init)
        return letters.count == 2 ? String(letters) : nil
    }
}

struct MapPlace {
    let coordinate: CLLocationCoordinate2D
    let city: String?
    let country: String?

    /// "Frankfurt, Germany", or whichever part is known.
    var name: String? {
        let parts = [city, country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct MapRequest: Identifiable {
    /// The country code: one arc per country.
    let id: String
    let host: String
    let flag: String
    let coordinate: CLLocationCoordinate2D
    let start: Date
}

/// Where the globe is seen from: straight down at a point, from a height above the ground.
struct GlobeCamera: Equatable {
    var latitude: Double
    var longitude: Double
    /// Metres above the ground.
    var distance: Double

    /// Makes the globe look `factor` times as big, between a country and the whole globe.
    mutating func zoom(by factor: Double) {
        let r = GlobeProjection.radius
        distance = min(max((r + distance) / factor - r, 1_500_000), 40_000_000)
    }
}

/// Country shapes and cities from Natural Earth (public domain, 1:110m), in `Globe.json` as
/// flat lon/lat lists rounded to 0.01°, turned into points on the unit sphere once.
private enum GlobeData {
    struct City {
        let name: String
        let point: SIMD3<Double>
        /// 0 for the largest cities.
        let rank: Int
    }

    static let shared = load()

    private static func load() -> (countries: [[[SIMD3<Double>]]], cities: [City]) {
        guard let url = Bundle.main.url(forResource: "Globe", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        let countries = (json["countries"] as? [[[Double]]] ?? []).map { rings in
            rings.map { flat in
                stride(from: 0, to: flat.count - 1, by: 2).map {
                    GlobeProjection.unit(CLLocationCoordinate2D(latitude: flat[$0 + 1], longitude: flat[$0]))
                }
            }
        }
        let cities = (json["cities"] as? [[Any]] ?? []).compactMap { row -> City? in
            guard row.count == 4, let name = row[0] as? String, let lat = row[1] as? Double,
                  let lon = row[2] as? Double, let rank = row[3] as? Int else { return nil }
            return City(name: name, point: GlobeProjection.unit(CLLocationCoordinate2D(latitude: lat, longitude: lon)), rank: rank)
        }
        return (countries, cities)
    }
}

/// How the camera sees the globe: a perspective view, straight down, north up.
private struct GlobeProjection {
    static let radius = 6_371_000.0
    static let fieldOfView = 30 * Double.pi / 180

    let eye, forward, right, up: SIMD3<Double>
    let focal: Double
    let middle: CGPoint
    /// Places whose direction from the centre of the earth is within this cosine of the camera's
    /// face it: the horizon seen from the camera's height.
    let horizon: Double
    /// The circle the globe fills on the screen.
    let rim: (center: CGPoint, radius: Double)

    init(camera: GlobeCamera, size: CGSize, middle: CGPoint) {
        let lat = camera.latitude * .pi / 180, lon = camera.longitude * .pi / 180
        let target = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        up = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        right = SIMD3(-sin(lon), cos(lon), 0)
        forward = -target
        let reach = Self.radius + camera.distance
        eye = target * reach
        focal = size.height / 2 / tan(Self.fieldOfView / 2)
        self.middle = middle
        horizon = Self.radius / reach
        rim = (middle, focal * tan(asin(horizon)))
    }

    static func unit(_ c: CLLocationCoordinate2D) -> SIMD3<Double> {
        let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
        return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    func faces(_ u: SIMD3<Double>) -> Bool { (u * -forward).sum() >= horizon }

    func point(_ c: CLLocationCoordinate2D) -> CGPoint? {
        let u = Self.unit(c)
        return faces(u) ? screen(u * Self.radius) : nil
    }

    /// Where p lands on the screen, hidden or not.
    func screen(_ p: SIMD3<Double>) -> CGPoint {
        let v = p - eye
        let depth = max((v * forward).sum(), 1)
        return CGPoint(x: middle.x + focal * (v * right).sum() / depth, y: middle.y - focal * (v * up).sum() / depth)
    }

    /// A line through points on the unit sphere, left out where it goes round the back.
    func line(_ points: [SIMD3<Double>]) -> Path {
        var path = Path()
        var drawing = false
        for u in points {
            guard faces(u) else { drawing = false; continue }
            let p = screen(u * Self.radius)
            if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
        }
        return path
    }

    /// Adds the part of a closed ring of points on the unit sphere that faces the camera, closed
    /// along the rim of the globe where the ring goes round the back.
    func addVisible(_ ring: [SIMD3<Double>], to path: inout Path) {
        guard var previous = ring.last else { return }
        var points: [CGPoint] = []
        var exit: CGPoint?
        // A ring that starts behind the globe comes into view before it first leaves it: that
        // entry joins up with its last exit.
        var firstEntry: CGPoint?
        var wasFacing = faces(previous)
        for u in ring {
            let facing = faces(u)
            if facing != wasFacing {
                let crossing = rimPoint(previous, u)
                if facing {
                    if let exit { points += rimArc(from: exit, to: crossing) } else { firstEntry = crossing }
                } else {
                    exit = crossing
                }
                points.append(crossing)
            }
            if facing { points.append(screen(u * Self.radius)) }
            previous = u
            wasFacing = facing
        }
        if let exit, let firstEntry { points += rimArc(from: exit, to: firstEntry) }
        guard points.count > 2 else { return }
        path.addLines(points)
        path.closeSubpath()
    }

    /// Where the edge from a to b crosses the horizon, on the rim.
    private func rimPoint(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> CGPoint {
        let da = (a * -forward).sum() - horizon, db = (b * -forward).sum() - horizon
        let u = a + (b - a) * (da / (da - db))
        let p = screen(u / (u * u).sum().squareRoot() * Self.radius)
        let dx = p.x - rim.center.x, dy = p.y - rim.center.y
        let length = max(hypot(dx, dy), 1e-9)
        return CGPoint(x: rim.center.x + dx / length * rim.radius, y: rim.center.y + dy / length * rim.radius)
    }

    /// Points along the rim from a to b the short way round.
    private func rimArc(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let start = atan2(a.y - rim.center.y, a.x - rim.center.x)
        var sweep = atan2(b.y - rim.center.y, b.x - rim.center.x) - start
        if sweep > .pi { sweep -= 2 * .pi } else if sweep < -.pi { sweep += 2 * .pi }
        let steps = max(Int(abs(sweep) / 0.08), 1)
        return (1..<steps).map { i in
            let angle = start + sweep * Double(i) / Double(steps)
            return CGPoint(x: rim.center.x + rim.radius * cos(angle), y: rim.center.y + rim.radius * sin(angle))
        }
    }

    /// The shortest way from a to b over the ground, following the curve of the globe.
    func ground(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Path {
        line((0...48).map { Self.along(a, b, Double($0) / 48) })
    }

    /// The point a share t of the way along the great circle from a to b, on the unit sphere.
    static func along(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> SIMD3<Double> {
        let p = unit(a), q = unit(b)
        let angle = acos(min(max((p * q).sum(), -1), 1))
        guard sin(angle) > 1e-9 else { return p }
        return (sin((1 - t) * angle) * p + sin(t * angle) * q) / sin(angle)
    }

    /// An arc from a to b on the screen, standing on the side away from the middle of the globe
    /// (up the screen when the two are about level with it), so it reads as a path through the
    /// sky. A true arc in the sky looks flat from straight above. Nil when either end is hidden.
    func arc(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Path? {
        guard let a = point(a), let b = point(b) else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = max(hypot(dx, dy), 1)
        var nx = -dy / chord, ny = dx / chord
        // Away from the middle, with a lean upwards so an arc across the middle does not flip.
        let away = ((a.x + b.x) / 2 - middle.x) * nx + ((a.y + b.y) / 2 - middle.y) * ny - ny * chord * 0.3
        if away < 0 { nx = -nx; ny = -ny }
        // Cubic handles of 4/3 of the height make the curve peak at that height.
        let k = chord * MapScene.lift * 4 / 3
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + nx * k, y: a.y + ny * k), control2: CGPoint(x: b.x + nx * k, y: b.y + ny * k))
        return path
    }
}

/// The globe itself: sea, land, borders, a grid of meridians and parallels, and city names.
private struct GlobeLayer: View, Equatable {
    let camera: GlobeCamera
    let middle: CGPoint
    let dark: Bool

    private static let grid: [[SIMD3<Double>]] = {
        let meridians = stride(from: -180.0, to: 180, by: 30).map { lon in
            stride(from: -90.0, through: 90, by: 3).map { GlobeProjection.unit(CLLocationCoordinate2D(latitude: $0, longitude: lon)) }
        }
        let parallels = stride(from: -60.0, through: 60, by: 30).map { lat in
            stride(from: -180.0, through: 180, by: 3).map { GlobeProjection.unit(CLLocationCoordinate2D(latitude: lat, longitude: $0)) }
        }
        return meridians + parallels
    }()

    var body: some View {
        Canvas { ctx, size in
            let globe = GlobeProjection(camera: camera, size: size, middle: middle)
            let (c, r) = globe.rim
            let disk = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let sea = dark ? Color(red: 0.07, green: 0.11, blue: 0.18) : Color(red: 0.80, green: 0.87, blue: 0.94)
            let land = dark ? Color(red: 0.17, green: 0.22, blue: 0.30) : Color(white: 0.985)
            let border = dark ? Color.white.opacity(0.22) : Color(red: 0.55, green: 0.62, blue: 0.70)
            let ink = dark ? Color.white : Color.black

            // A thin atmosphere around the rim.
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.1, y: c.y - r * 1.1, width: r * 2.2, height: r * 2.2)),
                     with: .radialGradient(Gradient(colors: [Color.blue.opacity(dark ? 0.35 : 0.18), .clear]),
                                           center: c, startRadius: r * 0.98, endRadius: r * 1.1))
            ctx.fill(disk, with: .color(sea))
            for line in Self.grid { ctx.stroke(globe.line(line), with: .color(ink.opacity(0.06)), lineWidth: 0.5) }
            for country in GlobeData.shared.countries {
                var shape = Path()
                for ring in country { globe.addVisible(ring, to: &shape) }
                guard !shape.isEmpty else { continue }
                ctx.fill(shape, with: .color(land), style: FillStyle(eoFill: true))
                ctx.stroke(shape, with: .color(border), lineWidth: 0.6)
            }
            // Light from the upper left, darker towards the rim: reads as a ball.
            ctx.fill(disk, with: .radialGradient(
                Gradient(stops: [.init(color: .white.opacity(dark ? 0.07 : 0.3), location: 0),
                                 .init(color: .clear, location: 0.5),
                                 .init(color: .black.opacity(dark ? 0.4 : 0.12), location: 1)]),
                center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.35), startRadius: 0, endRadius: r * 1.45))
            ctx.stroke(disk, with: .color(border), lineWidth: 1)
            drawCities(globe: globe, in: &ctx, ink: ink)
        }
    }

    /// The largest cities first; more as the globe comes closer, none overlapping another.
    private func drawCities(globe: GlobeProjection, in ctx: inout GraphicsContext, ink: Color) {
        let ranks = camera.distance > 15_000_000 ? 0 : camera.distance > 7_000_000 ? 1 : camera.distance > 3_500_000 ? 3 : 9
        var taken: [CGRect] = []
        for city in GlobeData.shared.cities where city.rank <= ranks && globe.faces(city.point) {
            let p = globe.screen(city.point * GlobeProjection.radius)
            let text = ctx.resolve(Text(city.name).font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.65)))
            let size = text.measure(in: CGSize(width: 200, height: 20))
            let frame = CGRect(x: p.x - 3, y: p.y - size.height / 2, width: size.width + 9, height: size.height)
            guard !taken.contains(where: { $0.intersects(frame) }) else { continue }
            taken.append(frame)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(ink.opacity(0.55)))
            ctx.draw(text, at: CGPoint(x: p.x + 6, y: p.y), anchor: .leading)
        }
    }
}

/// Everything the canvas draws for one frame.
private struct MapScene {
    var camera: GlobeCamera
    var middle: CGPoint
    var user: CLLocationCoordinate2D?
    var server: CLLocationCoordinate2D?
    var requests: [MapRequest]
    var live: Bool
    var animate: Bool

    static let you = Color.blue
    static let link = Color.orange
    static let request = Color.cyan
    var serverColor: Color { live ? .green : .gray }

    /// How high an arc rises, as a share of the distance it spans: one half would be a half circle.
    static let lift = 0.22
    /// Seconds a request takes to reach its destination, then to fade there.
    static let travel = 1.6, linger = 1.4

    func draw(in ctx: inout GraphicsContext, size: CGSize, at date: Date) {
        let time = date.timeIntervalSinceReferenceDate
        let globe = GlobeProjection(camera: camera, size: size, middle: middle)
        if let server {
            for request in requests { drawRequest(request, from: server, globe: globe, in: &ctx, at: date) }
        }
        if let user, let server { drawLink(user, server, globe: globe, in: &ctx, time: time) }
        if let user, let p = globe.point(user) { drawEndpoint(p, color: Self.you, tag: .you, in: &ctx, time: time) }
        if let server, let p = globe.point(server) { drawEndpoint(p, color: serverColor, tag: .server, in: &ctx, time: time + 0.7) }
    }

    /// The route from you to the server on the ground, glowing slowly while connected, with a
    /// chain link in the middle.
    private func drawLink(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, globe: GlobeProjection,
                          in ctx: inout GraphicsContext, time: Double) {
        let path = globe.ground(a, b)
        let color = live ? Self.link : .gray
        if live {
            // One slow breath every five seconds; held at its middle without motion. Two wide
            // faint strokes instead of a blur, which costs a pass over the whole layer.
            let breath = animate ? 0.5 + 0.5 * sin(time * 2 * .pi / 5) : 0.5
            ctx.stroke(path, with: .color(Self.link.opacity(0.08 + 0.14 * breath)), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            ctx.stroke(path, with: .color(Self.link.opacity(0.15 + 0.25 * breath)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: live ? [] : [4, 5]))
        let half = GlobeProjection.along(a, b, 0.5)
        if globe.faces(half), let chain = ctx.resolveSymbol(id: MapSymbol.chain) {
            ctx.draw(chain, at: globe.screen(half * GlobeProjection.radius))
        }
    }

    /// An arc from the server to the destination with a comet running along it, then a ripple
    /// and the host name where it lands.
    private func drawRequest(_ request: MapRequest, from server: CLLocationCoordinate2D, globe: GlobeProjection,
                             in ctx: inout GraphicsContext, at date: Date) {
        // ponytail: a destination on the far side of the globe gets no arc; the list still shows it.
        guard let path = globe.arc(server, request.coordinate), let target = globe.point(request.coordinate) else { return }
        guard animate else {
            ctx.stroke(path, with: .color(Self.request.opacity(0.35)), lineWidth: 1)
            Self.dot(at: target, radius: 2.5, color: Self.request, in: &ctx)
            return
        }
        let age = date.timeIntervalSince(request.start)
        // The arc fades in, then stays while the country has open connections.
        ctx.stroke(path, with: .color(Self.request.opacity(0.35 * min(age / 0.3, 1))), lineWidth: 1.4)
        if age < Self.travel {
            let t = age / Self.travel
            let p = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // ease in and out
            let tail = max(0, p - 0.25)
            guard let head = path.trimmedPath(from: 0, to: p).currentPoint else { return }
            let tailPoint = path.trimmedPath(from: 0, to: tail).currentPoint ?? head
            let streak = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Self.request.opacity(0), Self.request]), startPoint: tailPoint, endPoint: head)
            let trail = path.trimmedPath(from: tail, to: p)
            var glow = ctx
            glow.opacity = 0.3
            glow.stroke(trail, with: streak, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            ctx.stroke(trail, with: streak, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Self.dot(at: head, radius: 3, color: .white, glow: Self.request, in: &ctx)
        } else {
            let b = target
            // The landing ripples once, then the dot and its label stay.
            let f = min((age - Self.travel) / Self.linger, 1)
            for k in 0..<2 where f < 1 {
                let ring = min(max(f * 1.3 - Double(k) * 0.3, 0), 1)
                let r = 3 + ring * 22
                ctx.stroke(Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2)),
                           with: .color(Self.request.opacity((1 - ring) * 0.9)), lineWidth: 1.5)
            }
            Self.dot(at: b, radius: 3, color: Self.request, glow: Self.request, in: &ctx)
            if let tag = ctx.resolveSymbol(id: MapSymbol.host(request.host)) {
                ctx.draw(tag, at: CGPoint(x: b.x, y: b.y - 14), anchor: .bottom)
            }
        }
    }

    private func drawEndpoint(_ p: CGPoint, color: Color, tag: MapSymbol, in ctx: inout GraphicsContext, time: Double) {
        if animate {
            for k in 0..<2 {
                let phase = (time / 2.2 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
                let r = 8 + phase * 26
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                           with: .color(color.opacity((1 - phase) * 0.7)), lineWidth: 1.5)
            }
        }
        Self.halo(at: p, radius: 16, color: color.opacity(0.7), in: &ctx)
        let core = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        ctx.fill(core, with: .color(color))
        ctx.stroke(core, with: .color(.white), lineWidth: 2)
        if let label = ctx.resolveSymbol(id: tag) { ctx.draw(label, at: CGPoint(x: p.x, y: p.y + 16), anchor: .top) }
    }

    /// A soft glow as a gradient: a blur filter costs a pass over the whole layer.
    private static func halo(at p: CGPoint, radius: CGFloat, color: Color, in ctx: inout GraphicsContext) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                 with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: p, startRadius: 0, endRadius: radius))
    }

    private static func dot(at p: CGPoint?, radius: CGFloat, color: Color, glow: Color? = nil, in ctx: inout GraphicsContext) {
        guard let p else { return }
        if let glow { halo(at: p, radius: radius * 3, color: glow, in: &ctx) }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
    }
}

private enum MapSymbol: Hashable {
    case you, server, chain
    case host(String)
}

/// A name on a dark plate, made once as a canvas symbol and placed on every frame.
private struct MapTag: View {
    let title: String
    var subtitle: String?
    var small = false

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(small ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.7)) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
        .fixedSize()
    }
}

/// The chain link in the middle of the route.
private struct ChainBadge: View {
    let color: Color

    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(.black.opacity(0.65), in: .circle)
            .overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
    }
}

/// "Tehran, Iran → Frankfurt, Germany" with the distance between them.
private struct RouteCard: View {
    let user: MapPlace?
    let server: MapPlace?
    let serverTitle: String
    let flag: String?
    let live: Bool

    var body: some View {
        HStack(spacing: 14) {
            end(title: "You", value: Text(user?.name ?? "—"), color: .blue)
            Image(systemName: "arrow.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(live ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            end(title: "VPN · \(serverTitle)", value: Text("\(flag ?? "") \(server?.name ?? "—")"), color: live ? .green : .gray)
            if let user = user?.coordinate, let server = server?.coordinate {
                Divider().frame(height: 28)
                let meters = CLLocation(latitude: user.latitude, longitude: user.longitude)
                    .distance(from: CLLocation(latitude: server.latitude, longitude: server.longitude))
                end(title: "Distance",
                    value: Text(Measurement(value: meters, unit: UnitLength.meters), format: .measurement(width: .abbreviated, usage: .road)),
                    color: nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func end(title: LocalizedStringKey, value: Text, color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            value.font(.callout.weight(.semibold)).lineLimit(1)
        }
    }
}

/// The latest connections, newest on top, each with its app and where it went.
private struct RequestFeed: View {
    let connections: [ConnectionWatcher.Connection]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Requests", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(connections) { c in
                HStack(spacing: 7) {
                    if let app = c.app {
                        EntryIcon(entry: RuleEntry(.app, app)).scaleEffect(0.66).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "network").foregroundStyle(.tertiary).frame(width: 16)
                    }
                    Text(c.host).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Circle()
                        .fill(CustomRule.Action(rawValue: c.outbound).map { RuleList($0).tint } ?? .secondary)
                        .frame(width: 6, height: 6)
                }
                .font(.caption)
                .transition(.asymmetric(insertion: .push(from: .top), removal: .opacity))
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .animation(.snappy, value: connections.first?.id)
    }
}

/// The apps that moved the most data while the window has been open.
private struct TopApps: View {
    let connections: [ConnectionWatcher.Connection]

    var body: some View {
        let byApp = Dictionary(grouping: connections.filter { $0.app != nil }, by: { $0.app! })
            .map { (app: $0.key, bytes: $0.value.reduce(0) { $0 + $1.sent + $1.received }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(4)
        if !byApp.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Top apps", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(byApp), id: \.app) { item in
                    HStack(spacing: 8) {
                        EntryIcon(entry: RuleEntry(.app, item.app)).scaleEffect(0.75).frame(width: 18, height: 18)
                        Text(((item.app as NSString).lastPathComponent as NSString).deletingPathExtension).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.bytes.formatted(.byteCount(style: .file, spellsOutZero: false)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .frame(width: 240, alignment: .leading)
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}
