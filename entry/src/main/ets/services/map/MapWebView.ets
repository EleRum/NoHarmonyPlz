/**
 * Cross-platform Map component using WebView
 * Replaces MapComponent from @kit.MapKit for OpenHarmony builds
 */
import { webview } from '@kit.ArkWeb';

@Component
export struct MapWebView {
  onControllerAttached?: (controller: webview.WebviewController) => void;
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Web({ src: $rawfile('map/map.html'), controller: this.controller })
      .javaScriptAccess(true)
      .onControllerAttached(() => {
        if (this.onControllerAttached) {
          this.onControllerAttached(this.controller);
        }
      });
  }
}
