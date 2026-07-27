import Foundation

// Built-in status orb modules — the offline catalog + the cross-platform
// fallback rule. The module documents are embedded as the exact JSON the web
// client compiles in, and decoded through the same path as fetched modules so
// both platforms agree on the documents byte-for-byte. Kept apart from the
// model/renderer (OrbModules.swift) because the JSON payload is large data, not
// logic. The classic module is the universal fallback every renderer resolves
// to when a referenced module is missing.

// MARK: - Built-in modules

/// The built-in modules, embedded as the exact JSON the web client compiles
/// in (exported from nova-ha-dashboard/lib/orb-modules.ts). Decoding them
/// through the same path as fetched modules guarantees both platforms agree
/// on the documents byte-for-byte. The classic module is the universal
/// fallback every renderer resolves to when a referenced module is missing.
enum OrbModuleCatalog {
    static let builtins: [OrbModule] = {
        let data = Data(builtinOrbModulesJSON.utf8)
        return (try? JSONDecoder().decode([OrbModule].self, from: data)) ?? []
    }()

    static let builtinMap: [String: OrbModule] = Dictionary(
        uniqueKeysWithValues: builtins.map { ($0.id, $0) }
    )

    static var classic: OrbModule? {
        builtinMap["classic"]
    }

    /// The single cross-platform fallback rule: requested id -> fetched map
    /// -> built-ins -> classic.
    static func resolve(id: String?, fetched: [String: OrbModule]) -> OrbModule? {
        if let id, isValidOrbModuleID(id) {
            if let module = fetched[id] {
                return module
            }
            if let module = builtinMap[id] {
                return module
            }
        }
        return fetched["classic"] ?? classic
    }
}

// MARK: - Built-in module documents

// Exported verbatim from nova-ha-dashboard/lib/orb-modules.ts
// (BUILTIN_ORB_MODULES). Regenerate with:
//   node --experimental-strip-types -e 'import("./lib/orb-modules.ts")
//     .then(m => console.log(JSON.stringify(m.BUILTIN_ORB_MODULES, null, 2)))'
// from the nova-ha-dashboard repo whenever the built-ins change.
private let builtinOrbModulesJSON = #"""
[
  {
    "formatVersion": 1,
    "id": "classic",
    "name": "Classic Glass",
    "description": "Radial gradient core, fifty additive arcs, glass gloss.",
    "alertPulsePeriod": 1.2,
    "layers": [
      {
        "id": "background",
        "type": "disc",
        "stops": [
          {
            "at": 0,
            "color": {
              "theme": "gradientCenter"
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "gradientOuter",
              "alertTheme": "gradientAlert"
            }
          }
        ]
      },
      {
        "id": "load-arcs",
        "type": "arcField",
        "blend": "additive",
        "glow": 0.5208,
        "count": 50,
        "radiusMin": 0.1,
        "radiusMax": 0.95,
        "ringJitter": 0.08,
        "widthMin": 0.0104,
        "widthMax": 0.0833,
        "colors": [
          {
            "theme": "line1"
          },
          {
            "theme": "line2"
          },
          {
            "theme": "line3"
          }
        ],
        "idleSweepMin": 0.00025,
        "idleSweepMax": 0.001,
        "loadSweep": 1,
        "speedMin": 0.0557,
        "speedMax": 0.1194,
        "loadSpeed": 0.2546
      },
      {
        "id": "bevel-light",
        "type": "ring",
        "radius": 1.0081,
        "width": 0.0163,
        "color": {
          "hex": "#ffffff",
          "alpha": 0.05
        },
        "glow": 0.5208
      },
      {
        "id": "bevel-shadow",
        "type": "ring",
        "radius": 0.9512,
        "width": 0.0488,
        "color": {
          "theme": "innerShadow"
        },
        "glow": 0.5208
      },
      {
        "id": "bottom-vignette",
        "type": "disc",
        "clip": true,
        "gradientFrom": {
          "x": 0,
          "y": 0.55,
          "radius": 0.15
        },
        "gradientTo": {
          "x": 0,
          "y": 0.25,
          "radius": 1.05
        },
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#000000",
              "alpha": 0
            }
          },
          {
            "at": 0.7,
            "color": {
              "hex": "#000000",
              "alpha": 0
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "innerShadow"
            }
          }
        ]
      },
      {
        "id": "cap-highlight",
        "type": "disc",
        "clip": true,
        "center": {
          "x": -0.0833,
          "y": -0.42
        },
        "radius": 0.66,
        "scaleY": 0.5152,
        "rotation": -0.03,
        "gradientFrom": {
          "x": -0.0833,
          "y": -0.318,
          "radius": 0
        },
        "gradientTo": {
          "x": -0.0833,
          "y": -0.42,
          "radius": 0.693
        },
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.675
            }
          },
          {
            "at": 0.45,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.24
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "rim-streak",
        "type": "arc",
        "clip": true,
        "radius": 0.8617,
        "width": 0.1058,
        "from": 0.54,
        "to": 0.8,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          },
          {
            "at": 0.4,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.525
            }
          },
          {
            "at": 0.65,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.225
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "kiss-highlight",
        "type": "disc",
        "clip": true,
        "center": {
          "x": 0.5,
          "y": -0.38
        },
        "radius": 0.16,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.75
            }
          },
          {
            "at": 0.5,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.225
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "refraction-band",
        "type": "arc",
        "clip": true,
        "radius": 0.9186,
        "width": 0.0651,
        "from": 0.04,
        "to": 0.21,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          },
          {
            "at": 0.5,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.21
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "lower-rim-right",
        "type": "arc",
        "clip": true,
        "radius": 0.8617,
        "width": 0.0895,
        "from": 0.025,
        "to": 0.23,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          },
          {
            "at": 0.35,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.225
            }
          },
          {
            "at": 0.6,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.15
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "lower-rim-left",
        "type": "arc",
        "clip": true,
        "radius": 0.8617,
        "width": 0.0895,
        "from": 0.27,
        "to": 0.475,
        "reverse": true,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          },
          {
            "at": 0.35,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.225
            }
          },
          {
            "at": 0.6,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.15
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      }
    ]
  },
  {
    "formatVersion": 1,
    "id": "reactor",
    "name": "Reactor Core",
    "description": "Bright pulsing core with thick coil arcs on three rings.",
    "alertPulsePeriod": 1,
    "layers": [
      {
        "id": "shell",
        "type": "disc",
        "stops": [
          {
            "at": 0,
            "color": {
              "theme": "gradientOuter",
              "alpha": 0.85
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#000000"
            }
          }
        ]
      },
      {
        "id": "core-bloom",
        "type": "disc",
        "blend": "screen",
        "clip": true,
        "radius": 0.62,
        "stops": [
          {
            "at": 0,
            "color": {
              "theme": "gradientCenter"
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "gradientCenter",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "coils",
        "type": "arcField",
        "blend": "additive",
        "glow": 0.35,
        "count": 9,
        "radiusMin": 0.38,
        "radiusMax": 0.86,
        "distribution": "rings",
        "ringCount": 3,
        "widthMin": 0.05,
        "widthMax": 0.09,
        "colors": [
          {
            "theme": "line1"
          },
          {
            "theme": "line2"
          },
          {
            "theme": "line3"
          }
        ],
        "idleSweepMin": 0.06,
        "idleSweepMax": 0.14,
        "loadSweep": 0.42,
        "speedMin": 0.02,
        "speedMax": 0.07,
        "loadSpeed": 0.45,
        "sweepEase": 2,
        "velocityEase": 2
      },
      {
        "id": "core",
        "type": "disc",
        "blend": "additive",
        "radius": 0.2,
        "pulse": {
          "period": 3.2,
          "min": 0.7,
          "max": 1
        },
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.9
            }
          },
          {
            "at": 0.45,
            "color": {
              "theme": "gradientCenter",
              "alpha": 0.6
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "gradientCenter",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "containment-ring",
        "type": "ring",
        "radius": 0.96,
        "width": 0.02,
        "color": {
          "theme": "line1",
          "alpha": 0.55
        },
        "glow": 0.2
      },
      {
        "id": "bevel-shadow",
        "type": "ring",
        "radius": 0.93,
        "width": 0.06,
        "color": {
          "theme": "innerShadow"
        },
        "glow": 0.3
      },
      {
        "id": "alert-flash",
        "type": "ring",
        "blend": "additive",
        "radius": 0.9,
        "width": 0.05,
        "color": {
          "theme": "gradientAlert"
        },
        "glow": 0.4,
        "pulse": {
          "period": 1,
          "min": 0,
          "max": 0.9,
          "alertOnly": true
        }
      },
      {
        "id": "cap-highlight",
        "type": "disc",
        "clip": true,
        "center": {
          "x": 0,
          "y": -0.5
        },
        "radius": 0.55,
        "scaleY": 0.45,
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#ffffff",
              "alpha": 0.28
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#ffffff",
              "alpha": 0
            }
          }
        ]
      }
    ]
  },
  {
    "formatVersion": 1,
    "id": "halo",
    "name": "Halo",
    "description": "Open center with a fine arc swarm on a narrow outer band.",
    "alertPulsePeriod": 1.6,
    "settings": [
      {
        "id": "fibers",
        "label": "Fibres",
        "description": "Strands in the halo ring",
        "min": 1,
        "max": 12,
        "step": 1,
        "default": 1
      },
      {
        "id": "chaos",
        "label": "Chaos",
        "description": "0 = perfect circle, 100 = crackling lightning",
        "min": 0,
        "max": 100,
        "step": 1,
        "default": 0
      },
      {
        "id": "weave",
        "label": "Weave",
        "description": "How independently the strands wander and cross",
        "min": 0,
        "max": 100,
        "step": 1,
        "default": 30
      },
      {
        "id": "speed",
        "label": "Speed",
        "description": "How fast the ring pulses and the strands writhe",
        "min": 0,
        "max": 100,
        "step": 1,
        "default": 30
      },
      {
        "id": "pulse",
        "label": "Pulse",
        "description": "Breathing depth of the ring",
        "min": 0,
        "max": 100,
        "step": 1,
        "default": 20
      },
      {
        "id": "softness",
        "label": "Softness",
        "description": "Glow and edge softening on the strands",
        "min": 0,
        "max": 100,
        "step": 1,
        "default": 40
      }
    ],
    "layers": [
      {
        "id": "center-glow",
        "type": "disc",
        "blend": "screen",
        "radius": 0.55,
        "stops": [
          {
            "at": 0,
            "color": {
              "theme": "gradientCenter",
              "alpha": 0.5
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "gradientCenter",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "halo-ring",
        "type": "ring",
        "blend": "additive",
        "radius": 0.8,
        "width": 0.025,
        "color": {
          "theme": "gradientOuter",
          "alpha": 0.9,
          "alertTheme": "gradientAlert"
        },
        "glow": 0.45,
        "turbulence": {
          "fibers": {
            "setting": "fibers"
          },
          "chaos": {
            "setting": "chaos"
          },
          "weave": {
            "setting": "weave"
          },
          "speed": {
            "setting": "speed"
          },
          "pulse": {
            "setting": "pulse"
          },
          "softness": {
            "setting": "softness"
          }
        }
      },
      {
        "id": "band-swarm",
        "type": "arcField",
        "blend": "additive",
        "glow": 0.25,
        "count": 80,
        "radiusMin": 0.68,
        "radiusMax": 0.95,
        "ringJitter": 0.04,
        "widthMin": 0.006,
        "widthMax": 0.016,
        "colors": [
          {
            "theme": "line1"
          },
          {
            "theme": "line2"
          },
          {
            "theme": "line3"
          }
        ],
        "idleSweepMin": 0.02,
        "idleSweepMax": 0.1,
        "loadSweep": 0.35,
        "speedMin": 0.03,
        "speedMax": 0.09,
        "loadSpeed": 0.6
      },
      {
        "id": "inner-ring",
        "type": "ring",
        "radius": 0.62,
        "width": 0.008,
        "color": {
          "theme": "line3",
          "alpha": 0.35
        }
      },
      {
        "id": "alert-beacon",
        "type": "disc",
        "blend": "additive",
        "center": {
          "x": 0,
          "y": -0.8
        },
        "radius": 0.09,
        "pulse": {
          "period": 1.6,
          "min": 0,
          "max": 1,
          "alertOnly": true
        },
        "stops": [
          {
            "at": 0,
            "color": {
              "theme": "gradientAlert"
            }
          },
          {
            "at": 1,
            "color": {
              "theme": "gradientAlert",
              "alpha": 0
            }
          }
        ]
      }
    ]
  },
  {
    "formatVersion": 1,
    "id": "cross",
    "name": "Cross",
    "description": "Diamond-framed X with status lines riding its bars.",
    "alertPulsePeriod": 1.2,
    "layers": [
      {
        "id": "backing",
        "type": "disc",
        "stops": [
          {
            "at": 0,
            "color": {
              "hex": "#000000",
              "alpha": 0.5
            }
          },
          {
            "at": 1,
            "color": {
              "hex": "#000000",
              "alpha": 0
            }
          }
        ]
      },
      {
        "id": "x-bar-desc",
        "type": "line",
        "from": {
          "x": -0.5,
          "y": -0.5
        },
        "to": {
          "x": 0.5,
          "y": 0.5
        },
        "width": 0.18,
        "color": {
          "theme": "gradientCenter",
          "alertTheme": "gradientAlert"
        },
        "cap": "butt"
      },
      {
        "id": "x-bar-asc",
        "type": "line",
        "from": {
          "x": -0.5,
          "y": 0.5
        },
        "to": {
          "x": 0.5,
          "y": -0.5
        },
        "width": 0.18,
        "color": {
          "theme": "gradientCenter",
          "alertTheme": "gradientAlert"
        },
        "cap": "butt"
      },
      {
        "id": "status-lines",
        "type": "lineField",
        "blend": "additive",
        "glow": 0.3,
        "count": 6,
        "tracks": [
          {
            "from": {
              "x": -0.5,
              "y": -0.5
            },
            "to": {
              "x": 0.5,
              "y": 0.5
            }
          },
          {
            "from": {
              "x": -0.5,
              "y": 0.5
            },
            "to": {
              "x": 0.5,
              "y": -0.5
            }
          }
        ],
        "widthMin": 0.05,
        "widthMax": 0.07,
        "colors": [
          {
            "theme": "line1"
          },
          {
            "theme": "line2"
          },
          {
            "theme": "line3"
          }
        ],
        "colorMode": "random",
        "idleLengthMin": 0.12,
        "idleLengthMax": 0.22,
        "loadLength": 0.9,
        "speedMin": 0.12,
        "speedMax": 0.3,
        "loadSpeed": 0.45
      },
      {
        "id": "frame",
        "type": "polygon",
        "points": [
          {
            "x": 0,
            "y": -0.92
          },
          {
            "x": 0.92,
            "y": 0
          },
          {
            "x": 0,
            "y": 0.92
          },
          {
            "x": -0.92,
            "y": 0
          }
        ],
        "color": {
          "theme": "gradientOuter"
        },
        "width": 0.055
      },
      {
        "id": "accent-n",
        "type": "polygon",
        "points": [
          {
            "x": 0,
            "y": -0.78
          },
          {
            "x": 0.06,
            "y": -0.72
          },
          {
            "x": 0,
            "y": -0.66
          },
          {
            "x": -0.06,
            "y": -0.72
          }
        ],
        "color": {
          "theme": "gradientOuter"
        },
        "fill": true
      },
      {
        "id": "accent-e",
        "type": "polygon",
        "points": [
          {
            "x": 0.72,
            "y": -0.06
          },
          {
            "x": 0.78,
            "y": 0
          },
          {
            "x": 0.72,
            "y": 0.06
          },
          {
            "x": 0.66,
            "y": 0
          }
        ],
        "color": {
          "theme": "gradientOuter"
        },
        "fill": true
      },
      {
        "id": "accent-s",
        "type": "polygon",
        "points": [
          {
            "x": 0,
            "y": 0.66
          },
          {
            "x": 0.06,
            "y": 0.72
          },
          {
            "x": 0,
            "y": 0.78
          },
          {
            "x": -0.06,
            "y": 0.72
          }
        ],
        "color": {
          "theme": "gradientOuter"
        },
        "fill": true
      },
      {
        "id": "accent-w",
        "type": "polygon",
        "points": [
          {
            "x": -0.72,
            "y": -0.06
          },
          {
            "x": -0.66,
            "y": 0
          },
          {
            "x": -0.72,
            "y": 0.06
          },
          {
            "x": -0.78,
            "y": 0
          }
        ],
        "color": {
          "theme": "gradientOuter"
        },
        "fill": true
      },
      {
        "id": "alert-frame",
        "type": "polygon",
        "blend": "additive",
        "glow": 0.4,
        "pulse": {
          "period": 1.2,
          "min": 0,
          "max": 1,
          "alertOnly": true
        },
        "points": [
          {
            "x": 0,
            "y": -0.92
          },
          {
            "x": 0.92,
            "y": 0
          },
          {
            "x": 0,
            "y": 0.92
          },
          {
            "x": -0.92,
            "y": 0
          }
        ],
        "color": {
          "theme": "gradientAlert"
        },
        "width": 0.055
      }
    ]
  }
]
"""#
