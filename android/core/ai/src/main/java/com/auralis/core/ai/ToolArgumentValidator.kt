// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
package com.auralis.core.ai

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// ---------------------------------------------------------------------------
// AI-07：工具参数 JSON Schema 校验（唯一执行边界 registry.execute 前置调用）。
//
// 背景：模型可能产出畸形参数（非 object / 缺必填 / 类型错误 / 越界），旧实现
// `argumentObject ?: emptyMap()` 把它们静默降级成空调用——无参执行器（如 next）
// 收到 `{}` 照样切歌，意图被静默执行。
//
// 这里手写覆盖 schema 子集的轻量校验器（不引第三方依赖）：
// - 根必须是 JSON object；
// - required、基础类型（string/number/integer/boolean/array/object）、enum、
//   数值范围（minimum/maximum，含边界）、additionalProperties=false 拒绝未知字段；
// - object 的 properties 与 array 的 items 递归校验；
// - schema 缺失或无法解析时走保守策略：视为无参工具，仅接受空对象。
// ---------------------------------------------------------------------------

/** 参数校验失败（AI-07）：不执行工具，reason 回灌给模型修正。 */
class MalformedToolArguments(
    val operation: String,
    val reason: String,
) : Exception("malformed_arguments: $reason")

object ToolArgumentValidator {

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * 校验 [arguments] 是否符合 [schemaJson]；通过返回 null，失败返回可读原因。
     */
    fun validate(operation: String, schemaJson: String?, arguments: JsonElement): String? {
        val obj = arguments as? JsonObject
            ?: return "参数必须是 JSON object，实际为 ${describe(arguments)}"
        val schema = schemaJson?.takeIf { it.isNotBlank() }
            ?.let { raw -> runCatching { json.parseToJsonElement(raw) as? JsonObject }.getOrNull() }
        if (schema == null) {
            // 保守策略：schema 缺失/无法解析 → 无参工具，仅接受空对象。
            return if (obj.isEmpty()) null
            else "该工具不接受参数（schema 缺失按无参处理），实际收到字段：${obj.keys.joinToString()}"
        }
        return validateObject(schema, obj, path = "")
    }

    /** 校验器对外暴露的期望格式说明（回灌给模型）。 */
    fun expectedFormat(schemaJson: String?): String =
        schemaJson?.takeIf { it.isNotBlank() } ?: """空对象 {}"""

    // ------------------------------------------------------------------

    private fun validateObject(schema: JsonObject, obj: JsonObject, path: String): String? {
        val properties = schema["properties"] as? JsonObject ?: JsonObject(emptyMap())
        // required
        val required = schema["required"]?.let { el ->
            (el as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        }.orEmpty()
        for (key in required) {
            if (key !in obj || obj[key] is JsonNull) {
                return "缺少必填参数 ${quote(path + key)}"
            }
        }
        // additionalProperties 策略（保守）：显式 false 拒绝未知字段；
        // 未显式声明但给出了 properties（哪怕为空）也拒绝未知字段——无参工具的
        // `{"type":"object","properties":{}}` 由此拒绝垃圾参数，而只写
        // `{"type":"object"}` 的 free-form 对象（如 globalID）不受影响。
        val additional = (schema["additionalProperties"] as? JsonPrimitive)?.booleanOrNull
        val denyUnknown = additional == false || (additional == null && schema.containsKey("properties"))
        if (denyUnknown) {
            val unknown = obj.keys - properties.keys
            if (unknown.isNotEmpty()) {
                return "存在 schema 未声明的字段：${unknown.joinToString { quote(path + it) }}"
            }
        }
        // 逐字段校验。
        for ((key, value) in obj) {
            val sub = properties[key] as? JsonObject ?: continue // 未声明字段（additionalProperties 允许时跳过）
            validateValue(sub, value, path + key)?.let { return it }
        }
        return null
    }

    private fun validateValue(schema: JsonObject, value: JsonElement, path: String): String? {
        if (value is JsonNull) return null // null 由 required 语义处理；可选字段传 null 视为未提供
        // type
        when ((schema["type"] as? JsonPrimitive)?.contentOrNull) {
            "string" -> if (value !is JsonPrimitive || !value.isString) {
                return "参数 ${quote(path)} 期望 string，实际为 ${describe(value)}"
            }
            "number" -> if (!isNumericPrimitive(value)) {
                return "参数 ${quote(path)} 期望 number，实际为 ${describe(value)}"
            }
            "integer" -> {
                val n = if (isNumericPrimitive(value)) (value as JsonPrimitive).doubleOrNull else null
                if (n == null || n % 1.0 != 0.0) {
                    return "参数 ${quote(path)} 期望 integer，实际为 ${describe(value)}"
                }
            }
            "boolean" -> if ((value as? JsonPrimitive)?.booleanOrNull == null) {
                return "参数 ${quote(path)} 期望 boolean，实际为 ${describe(value)}"
            }
            "array" -> if (value !is JsonArray) {
                return "参数 ${quote(path)} 期望 array，实际为 ${describe(value)}"
            }
            "object" -> if (value !is JsonObject) {
                return "参数 ${quote(path)} 期望 object，实际为 ${describe(value)}"
            }
        }
        // enum（按 canonical JSON 文本或字符串内容比较）
        (schema["enum"] as? JsonArray)?.let { allowed ->
            val matched = allowed.any { candidate ->
                candidate == value ||
                    (candidate as? JsonPrimitive)?.contentOrNull == (value as? JsonPrimitive)?.contentOrNull
            }
            if (!matched) {
                return "参数 ${quote(path)} 不在枚举范围内：${allowed.joinToString()}"
            }
        }
        // minimum / maximum（含边界）
        val number = (value as? JsonPrimitive)?.doubleOrNull
        if (number != null) {
            (schema["minimum"] as? JsonPrimitive)?.doubleOrNull?.let { min ->
                if (number < min) return "参数 ${quote(path)} 小于下限 $min（实际 $number）"
            }
            (schema["maximum"] as? JsonPrimitive)?.doubleOrNull?.let { max ->
                if (number > max) return "参数 ${quote(path)} 超过上限 $max（实际 $number）"
            }
        }
        // 递归：object properties / array items
        if (value is JsonObject) {
            validateObject(schema, value, "$path.")?.let { return it }
        }
        if (value is JsonArray) {
            val items = schema["items"] as? JsonObject
            if (items != null) {
                value.forEachIndexed { index, item ->
                    validateValue(items, item, "$path[$index]")?.let { return it }
                }
            }
        }
        return null
    }

    /** JSON number 字面量（字符串 "12" 不算 number）。 */
    private fun isNumericPrimitive(value: JsonElement): Boolean =
        value is JsonPrimitive && !value.isString && value.doubleOrNull != null

    private fun describe(value: JsonElement): String = when (value) {
        is JsonNull -> "null"
        is JsonObject -> "object"
        is JsonArray -> "array"
        is JsonPrimitive -> if (value.isString) "string" else value.toString()
        else -> value.toString()
    }

    private fun quote(path: String): String = "\"$path\""
}
