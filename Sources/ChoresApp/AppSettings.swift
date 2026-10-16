import Foundation

/// `UserDefaults` keys for the app's own preferences.
enum AppSettings {
    static let showDisabledInMenu = "showDisabledInMenu"
    /// Report or log, whichever the user picked last; kept across runs, jobs and launches.
    static let outputPane = "outputPane"
    /// History or info on a job page, shared by the menu page and the window.
    static let detailTab = "detailTab"
}

/// The two tabs of a job page.
enum DetailTab: String {
    case history, info
}
