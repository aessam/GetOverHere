package com.aessam.comeoverhere.core

import com.aessam.toursession.BluetoothRoomRecord
import com.aessam.toursession.GatewayPairingMessage
import com.aessam.toursession.GatewayRoomDescriptor

/** Testable ownership boundary; production uses native certificate-pinned TLS. */
interface GatewayWiredInterface {
    var onDescriptor: ((GatewayRoomDescriptor?) -> Unit)?
    var onError: ((String) -> Unit)?
    var onConnected: ((Boolean) -> Unit)?
    val isConnected: Boolean
    val automaticRecoveryEnabled: Boolean get() = false
    val routeDescription: String?
    fun routeSnapshot(): WiredRouteDiagnostic?
    fun makeOffer(record: BluetoothRoomRecord, key: ByteArray, address: WiredInterfaceAddress,
                  current: () -> GatewayRoomDescriptor?): GatewayPairingMessage
    fun answerOffer(message: GatewayPairingMessage, address: WiredInterfaceAddress): GatewayPairingMessage
    fun confirmResponse(message: GatewayPairingMessage)
    fun startCompanion()
    fun stop()
}
