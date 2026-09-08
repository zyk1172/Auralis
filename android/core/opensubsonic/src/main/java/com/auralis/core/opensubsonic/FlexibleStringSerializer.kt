// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.opensubsonic

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * OpenSubsonic 的 id 既可能是字符串也可能是数字。
 * 对应 Apple `FlexibleString`：优先取字符串，否则取数字的原始字面量，缺失时空串。
 */
object FlexibleStringSerializer : KSerializer<FlexibleString> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("FlexibleString", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): FlexibleString {
        val jsonDecoder = decoder as? JsonDecoder
            ?: return FlexibleString(decoder.decodeString())
        val element = jsonDecoder.decodeJsonElement()
        val primitive = element as? JsonPrimitive
        return FlexibleString(primitive?.contentOrNull ?: element.toString().trim('"'))
    }

    override fun serialize(encoder: Encoder, value: FlexibleString) = encoder.encodeString(value.value)
}
