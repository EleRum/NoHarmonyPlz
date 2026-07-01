/**
 * 高德 JSAPI v2.0 地图桥接脚本
 * 运行在 WebView 中，负责：
 *   1. 初始化高德地图
 *   2. 接收 ArkTS 侧命令（通过 runJavaScript）
 *   3. 回调 ArkTS 侧事件（通过 javaScriptProxy → arkTsCallback）
 *
 * 通信协议：
 *   ArkTS → JS:  window.FootMapBridge.xxx(args)
 *   JS → ArkTS:  window.arkTsCallback(JSON.stringify({type, ...}))
 */

(function () {
  'use strict';

  // ═══════════════════════════════════════════
  //  状态
  // ═══════════════════════════════════════════
  var map = null;
  var markers = {};     // id → AMap.Marker
  var polylines = {};   // id → AMap.Polyline
  var placeSearch = null;
  var geocoder = null;
  var mapReady = false;

  // ═══════════════════════════════════════════
  //  ArkTS 回调
  // ═══════════════════════════════════════════
  function sendToArkTS(data) {
    try {
      if (window.arkTsCallback) {
        window.arkTsCallback(JSON.stringify(data));
      }
    } catch (e) {
      console.error('FootMapBridge: sendToArkTS error', e);
    }
  }

  // ═══════════════════════════════════════════
  //  初始化地图
  // ═══════════════════════════════════════════
  function initMap(configJson) {
    try {
      var config = typeof configJson === 'string' ? JSON.parse(configJson) : configJson;

      // 安全配置：允许 WebView 文件协议
      if (typeof AMap !== 'undefined' && AMap.security) {
        // AMap JSAPI v2.0 安全策略
      }

      map = new AMap.Map('container', {
        zoom: config.zoom || 15,
        center: [config.lng || 116.3974, config.lat || 39.9042],
        mapStyle: 'amap://styles/light',
        viewMode: '3D',
        pitch: config.pitch || 45,
        rotation: config.rotation || 0,
        buildingAnimation: true,
        resizeEnable: true,
        touchZoom: true,
        dragEnable: true,
        zoomEnable: true
      });

      // 地图点击事件
      map.on('click', function (e) {
        sendToArkTS({
          type: 'mapClick',
          lng: e.lnglat.getLng(),
          lat: e.lnglat.getLat()
        });
      });

      // 地图移动结束事件
      map.on('moveend', function () {
        var center = map.getCenter();
        sendToArkTS({
          type: 'mapMoveEnd',
          lng: center.getLng(),
          lat: center.getLat(),
          zoom: map.getZoom()
        });
      });

      // 初始化插件
      AMap.plugin(['AMap.PlaceSearch', 'AMap.Geocoder', 'AMap.Geolocation'], function () {
        placeSearch = new AMap.PlaceSearch({
          pageSize: 10,
          pageIndex: 1
        });
        geocoder = new AMap.Geocoder();

        mapReady = true;
        sendToArkTS({ type: 'mapReady' });
      });

    } catch (e) {
      console.error('FootMapBridge: initMap error', e);
    }
  }

  // ═══════════════════════════════════════════
  //  地图控制
  // ═══════════════════════════════════════════
  function mapSetCenter(lng, lat, zoom) {
    if (!map) return;
    if (zoom) {
      map.setZoomAndCenter(zoom, [lng, lat]);
    } else {
      map.setCenter([lng, lat]);
    }
  }

  function mapGetCenter() {
    if (!map) return JSON.stringify({ lng: 0, lat: 0, zoom: 0 });
    var c = map.getCenter();
    return JSON.stringify({ lng: c.getLng(), lat: c.getLat(), zoom: map.getZoom() });
  }

  function mapSetZoom(zoom) {
    if (!map) return;
    map.setZoom(zoom);
  }

  function mapFitBounds(swLng, swLat, neLng, neLat) {
    if (!map) return;
    map.setBounds(new AMap.Bounds([swLng, swLat], [neLng, neLat]));
  }

  // ═══════════════════════════════════════════
  //  标记点管理
  // ═══════════════════════════════════════════
  function mapAddMarker(id, lng, lat, title, iconUrl, draggable) {
    if (!map) return;
    removeMarker(id);

    var opts = {
      position: [lng, lat],
      title: title || '',
      map: map
    };
    if (iconUrl) {
      opts.icon = iconUrl;
    }
    if (draggable) {
      opts.draggable = true;
    }

    var marker = new AMap.Marker(opts);

    marker.on('click', function () {
      sendToArkTS({ type: 'markerClick', id: id, lng: lng, lat: lat, title: title });
    });

    markers[id] = marker;
  }

  function mapRemoveMarker(id) {
    var m = markers[id];
    if (m) {
      m.setMap(null);
      delete markers[id];
    }
  }

  function mapClearMarkers() {
    for (var id in markers) {
      if (markers.hasOwnProperty(id)) {
        markers[id].setMap(null);
      }
    }
    markers = {};
  }

  function mapSetMarkerPosition(id, lng, lat) {
    var m = markers[id];
    if (m) {
      m.setPosition([lng, lat]);
    }
  }

  function mapSetMarkerVisible(id, visible) {
    var m = markers[id];
    if (m) {
      m.setMap(visible ? map : null);
    }
  }

  /** 批量添加标记（性能优化：避免逐个 addMarker 的 JS 调用开销） */
  function mapAddMarkersBatch(markersJson) {
    if (!map) return;
    var list = typeof markersJson === 'string' ? JSON.parse(markersJson) : markersJson;
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      var opts = {
        position: [item.lng, item.lat],
        title: item.title || '',
        map: map
      };
      if (item.iconUrl) {
        opts.icon = new AMap.Icon({
          size: item.iconSize ? new AMap.Size(item.iconSize[0], item.iconSize[1]) : new AMap.Size(24, 32),
          image: item.iconUrl,
          imageSize: item.iconSize ? new AMap.Size(item.iconSize[0], item.iconSize[1]) : new AMap.Size(24, 32)
        });
      }
      var marker = new AMap.Marker(opts);
      (function (mid, mlng, mlat, mtitle) {
        marker.on('click', function () {
          sendToArkTS({ type: 'markerClick', id: mid, lng: mlng, lat: mlat, title: mtitle });
        });
      })(item.id, item.lng, item.lat, item.title);
      markers[item.id] = marker;
    }
  }

  // ═══════════════════════════════════════════
  //  折线管理
  // ═══════════════════════════════════════════
  function mapAddPolyline(id, pointsJson, color, width) {
    if (!map) return;
    removePolyline(id);

    var points = typeof pointsJson === 'string' ? JSON.parse(pointsJson) : pointsJson;
    var path = [];
    for (var i = 0; i < points.length; i++) {
      path.push([points[i].lng, points[i].lat]);
    }

    var polyline = new AMap.Polyline({
      path: path,
      strokeColor: color || '#3388ff',
      strokeWeight: width || 6,
      strokeOpacity: 0.8,
      lineJoin: 'round',
      lineCap: 'round',
      map: map,
      zIndex: 10
    });

    polylines[id] = polyline;
  }

  function mapSetPolylinePoints(id, pointsJson) {
    var p = polylines[id];
    if (!p) return;
    var points = typeof pointsJson === 'string' ? JSON.parse(pointsJson) : pointsJson;
    var path = [];
    for (var i = 0; i < points.length; i++) {
      path.push([points[i].lng, points[i].lat]);
    }
    p.setPath(path);
  }

  function mapRemovePolyline(id) {
    var p = polylines[id];
    if (p) {
      p.setMap(null);
      delete polylines[id];
    }
  }

  function mapSetPolylineVisible(id, visible) {
    var p = polylines[id];
    if (p) {
      p.setMap(visible ? map : null);
    }
  }

  function mapClearPolylines() {
    for (var id in polylines) {
      if (polylines.hasOwnProperty(id)) {
        polylines[id].setMap(null);
      }
    }
    polylines = {};
  }

  // ═══════════════════════════════════════════
  //  POI 搜索
  // ═══════════════════════════════════════════
  function mapSearchNearby(keywords, centerLng, centerLat, radius) {
    if (!placeSearch) {
      sendToArkTS({ type: 'searchResult', pois: [], error: 'PlaceSearch not ready' });
      return;
    }
    placeSearch.searchNearBy(keywords, [centerLng, centerLat], radius || 3000, function (status, result) {
      if (status === 'complete' && result.info === 'OK') {
        var pois = (result.poiList && result.poiList.pois) || [];
        var out = [];
        for (var i = 0; i < pois.length; i++) {
          var p = pois[i];
          out.push({
            name: p.name || '',
            type: p.type || '',
            lng: p.location ? p.location.getLng() : 0,
            lat: p.location ? p.location.getLat() : 0,
            address: p.address || '',
            distance: p.distance || 0,
            tel: p.tel || ''
          });
        }
        sendToArkTS({ type: 'searchResult', pois: out });
      } else {
        sendToArkTS({ type: 'searchResult', pois: [], error: result.info || 'search failed' });
      }
    });
  }

  /** 查找最近地点（逆地理 / 附近 POI） */
  function mapLookupNearestPlace(lng, lat) {
    if (!geocoder) {
      sendToArkTS({ type: 'geocodeResult', address: null, error: 'Geocoder not ready' });
      return;
    }
    geocoder.getAddress([lng, lat], function (status, result) {
      if (status === 'complete' && result.info === 'OK') {
        var addr = result.regeocode;
        sendToArkTS({
          type: 'geocodeResult',
          address: {
            formattedAddress: addr.formattedAddress || '',
            city: (addr.addressComponent && addr.addressComponent.city) || '',
            district: (addr.addressComponent && addr.addressComponent.district) || '',
            pois: (addr.pois || []).map(function (p) {
              return { name: p.name, type: p.type, direction: p.direction, distance: p.distance };
            })
          }
        });
      } else {
        sendToArkTS({ type: 'geocodeResult', address: null, error: result.info || 'geocode failed' });
      }
    });
  }

  // ═══════════════════════════════════════════
  //  我的位置
  // ═══════════════════════════════════════════
  function mapSetMyLocation(lng, lat) {
    if (!map) return;
    // 使用 JSAPI 的定位标记
    var pos = [lng, lat];
    if (!map._myLocationMarker) {
      map._myLocationMarker = new AMap.Marker({
        position: pos,
        map: map,
        zIndex: 1000,
        icon: new AMap.Icon({
          size: new AMap.Size(20, 20),
          image: 'data:image/svg+xml,' + encodeURIComponent(
            '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">' +
            '<circle cx="10" cy="10" r="8" fill="#3388ff" stroke="#fff" stroke-width="2"/>' +
            '<circle cx="10" cy="10" r="3" fill="#fff"/>' +
            '</svg>'
          ),
          imageSize: new AMap.Size(20, 20)
        })
      });
    } else {
      map._myLocationMarker.setPosition(pos);
    }
  }

  // ═══════════════════════════════════════════
  //  清理
  // ═══════════════════════════════════════════
  function mapDestroy() {
    mapClearMarkers();
    mapClearPolylines();
    if (map) {
      map.destroy();
      map = null;
    }
    mapReady = false;
  }

  // ═══════════════════════════════════════════
  //  导出 API（暴露给 ArkTS 侧 runJavaScript 调用）
  // ═══════════════════════════════════════════
  window.FootMapBridge = {
    initMap: initMap,
    setCenter: mapSetCenter,
    getCenter: mapGetCenter,
    setZoom: mapSetZoom,
    fitBounds: mapFitBounds,

    addMarker: mapAddMarker,
    removeMarker: mapRemoveMarker,
    clearMarkers: mapClearMarkers,
    setMarkerPosition: mapSetMarkerPosition,
    setMarkerVisible: mapSetMarkerVisible,
    addMarkersBatch: mapAddMarkersBatch,

    addPolyline: mapAddPolyline,
    setPolylinePoints: mapSetPolylinePoints,
    setPolylineVisible: mapSetPolylineVisible,
    removePolyline: mapRemovePolyline,
    clearPolylines: mapClearPolylines,

    searchNearby: mapSearchNearby,
    lookupNearestPlace: mapLookupNearestPlace,

    setMyLocation: mapSetMyLocation,
    destroy: mapDestroy,

    isReady: function () { return mapReady; }
  };

  console.log('FootMapBridge: JS bridge initialized');
})();
