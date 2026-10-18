package dev.homelab.homelab_control

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity, et non FlutterActivity : le déverrouillage par
// empreinte (local_auth) en a besoin.
class MainActivity : FlutterFragmentActivity()
