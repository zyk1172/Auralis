// SPDX-License-Identifier: GPL-3.0-only
package com.auralis.core.ai

import kotlinx.serialization.json.Json
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AI-07：ToolArgumentValidator 子集语义：
 * 根 object、required、基础类型、enum、数值范围、additionalProperties 策略、
 * 嵌套 properties/items、schema 缺失/损坏时的保守策略。
 */
class ToolArgumentValidatorTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun validate(schema: String?, args: String): String? =
        ToolArgumentValidator.validate("tool", schema, json.parseToJsonElement(args))

    private val searchSchema =
        """{"type":"object","properties":{"q":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50}},"required":["q"]}"""

    @Test
    fun `根必须是 object`() {
        assertNotNull(validate(searchSchema, "\"not json object\""))
        assertNotNull(validate(searchSchema, "[1,2]"))
        assertNotNull(validate(searchSchema, "null"))
        assertNotNull(validate(searchSchema, "42"))
    }

    @Test
    fun `required 缺失与类型错误被拒绝`() {
        assertTrue(validate(searchSchema, "{}")!!.contains("q"))
        assertTrue(validate(searchSchema, """{"limit":10}""")!!.contains("q"))
        assertNotNull(validate(searchSchema, """{"q":123}"""))
        assertNull(validate(searchSchema, """{"q":"夜曲"}"""))
        assertNull(validate(searchSchema, """{"q":"夜曲","limit":10}"""))
    }

    @Test
    fun `integer 不接受小数 number 接受`() {
        assertNotNull(validate(searchSchema, """{"q":"a","limit":1.5}"""))
        assertNull(validate(searchSchema, """{"q":"a","limit":2}"""))
        val numberSchema = """{"type":"object","properties":{"positionSeconds":{"type":"number"}},"required":["positionSeconds"]}"""
        assertNull(validate(numberSchema, """{"positionSeconds":12.5}"""))
        assertNotNull(validate(numberSchema, """{"positionSeconds":"12"}"""))
    }

    @Test
    fun `数值范围含边界`() {
        assertNotNull(validate(searchSchema, """{"q":"a","limit":0}"""))
        assertNotNull(validate(searchSchema, """{"q":"a","limit":51}"""))
        assertNull(validate(searchSchema, """{"q":"a","limit":1}"""))
        assertNull(validate(searchSchema, """{"q":"a","limit":50}"""))
    }

    @Test
    fun `enum 校验`() {
        val schema = """{"type":"object","properties":{"dimension":{"type":"string","enum":["mood","genre"]}},"required":["dimension"]}"""
        assertNull(validate(schema, """{"dimension":"mood"}"""))
        assertNotNull(validate(schema, """{"dimension":"other"}"""))
    }

    @Test
    fun `声明 properties 后未知字段被拒绝`() {
        assertNotNull(validate(searchSchema, """{"q":"a","junk":1}"""))
    }

    @Test
    fun `additionalProperties false 拒绝未知字段 true 放行`() {
        val closed = """{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}"""
        assertNotNull(validate(closed, """{"a":"x","b":1}"""))
        val open = """{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":true}"""
        assertNull(validate(open, """{"a":"x","b":1}"""))
    }

    @Test
    fun `free-form object 不受未知字段策略影响`() {
        // globalID 形状：只写 {"type":"object"}，字段不限。
        val schema = """{"type":"object","properties":{"globalID":{"type":"object"}},"required":["globalID"]}"""
        assertNull(validate(schema, """{"globalID":{"serverID":"s1","remoteID":"r1"}}"""))
        assertNotNull(validate(schema, """{"globalID":"s1:r1"}"""))
    }

    @Test
    fun `嵌套 object 与 array items 递归校验`() {
        val schema = """
          {"type":"object","properties":{
            "candidates":{"type":"array","items":{"type":"object","properties":{
              "title":{"type":"string"},"artist":{"type":"string"}
            },"required":["title"],"additionalProperties":false}}
          },"required":["candidates"]}
        """.trimIndent()
        assertNull(validate(schema, """{"candidates":[{"title":"夜曲","artist":"周杰伦"}]}"""))
        assertNotNull(validate(schema, """{"candidates":[{"artist":"周杰伦"}]}"""))
        assertNotNull(validate(schema, """{"candidates":[{"title":"夜曲","junk":1}]}"""))
        assertNotNull(validate(schema, """{"candidates":"夜曲"}"""))
    }

    @Test
    fun `schema 缺失或损坏时按无参工具处理`() {
        assertNull(validate(null, "{}"))
        assertNotNull(validate(null, """{"x":1}"""))
        assertNull(validate("not a schema", "{}"))
        assertNotNull(validate("not a schema", """{"x":1}"""))
        assertNull(validate("", "{}"))
    }

    @Test
    fun `空 properties 的无参工具拒绝垃圾字段`() {
        val empty = """{"type":"object","properties":{}}"""
        assertNull(validate(empty, "{}"))
        assertNotNull(validate(empty, """{"positionSeconds":"abc"}"""))
    }
}
