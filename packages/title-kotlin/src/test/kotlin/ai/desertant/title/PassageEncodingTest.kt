package ai.desertant.title

import ai.desertant.core.FfiReader
import org.junit.Assert.assertEquals
import org.junit.Test

class PassageEncodingTest {
    @Test fun keepsShortPassagesIntact() {
        val text = "日本👩🏽‍🔬"
        assertEquals(text, FfiReader(encodePassage(text)).string())
    }

    @Test fun boundsThePayloadWithoutSplittingASurrogatePair() {
        val prefix = "a".repeat(128 * 1_280 - 1)
        val completePair = FfiReader(encodePassage(prefix.dropLast(1) + "😀suffix")).string()
        val splitPair = FfiReader(encodePassage(prefix + "😀suffix")).string()
        assertEquals(prefix.dropLast(1) + "😀", completePair)
        assertEquals(prefix, splitPair)
    }
}
