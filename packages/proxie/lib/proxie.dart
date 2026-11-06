/// Proxie: in-app HTTP inspector for Flutter.
///
/// What an app needs. Adapter authors also import
/// `package:proxie/adapter.dart`.
library;

export 'src/adapters/capture_adapter.dart' show ProxieCaptureAdapter;
export 'src/adapters/http_client_adapter.dart' show ProxieHttpClient;
export 'src/adapters/http_overrides_stub.dart'
    if (dart.library.io) 'src/adapters/http_overrides_adapter.dart'
    show ProxieHttpOverridesAdapter;
export 'src/config.dart' show ProxieConfig, ProxieThemeMode;
export 'src/core/engine.dart' show ProxieEngine;
export 'src/core/masking.dart' show ProxieMasking, kMask;
export 'src/core/rule.dart'
    show
        BreakpointPhase,
        MapLocalAction,
        ProxieRule,
        RuleKind,
        RuleSet,
        SimulatedFailure;
export 'src/core/url_matcher.dart' show UrlMatcher;
export 'src/enablement.dart' show kProxieEnabled;
export 'src/model/body.dart' show BodyKind, ProxieBody, defaultBodyCap;
export 'src/model/call.dart' show CallTag, ProxieCall, ProxieError;
export 'src/model/request.dart' show ProxieRequest;
export 'src/model/response.dart' show ProxieResponse;
export 'src/navigation/navigation_adapter.dart'
    show
        AdapterNavigation,
        CustomNavigation,
        NavigatorKeyNavigation,
        OverlayNavigation,
        ProxieNavigation,
        ProxieNavigationAdapter;
export 'src/proxie.dart' show Proxie;
export 'src/storage/call_query.dart' show CallSummary;
export 'src/ui/sections.dart'
    show ProxieDetailTab, ProxieListBadge, ProxieSections;

/// Current package version.
const kProxieVersion = '0.1.0';
