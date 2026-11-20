package ai.desertant.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class FaceprintTest {
    /** Faceprints of different lengths come from different embedders: they never compare, in either order. */
    @Test fun faceprintsOfDifferentLengthsNeverCompare() {
        val a = Faceprint.of(FloatArray(128) { if (it < 2) 1f else 0f })
        val short = Faceprint.of(FloatArray(64) { if (it < 2) 1f else 0f })
        assertEquals(0.0, a.similarity(short), 0.0)
        assertEquals(0.0, short.similarity(a), 0.0)
        assertFalse(a.isSamePerson(short) || short.isSamePerson(a) || a.isComparable(short))
    }
}
