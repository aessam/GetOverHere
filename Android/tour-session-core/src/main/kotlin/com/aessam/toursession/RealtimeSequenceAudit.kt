package com.aessam.toursession

data class RealtimeSequenceAudit(
    val uniquePackets: Int,
    val duplicatePackets: Int,
    val reorderedPackets: Int,
    val missingPackets: Long,
) {
    val report: String
        get() = "unique=$uniquePackets|duplicates=$duplicatePackets|reordered=$reorderedPackets|missing=$missingPackets"

    companion object {
        fun analyze(sequences: List<Long>): RealtimeSequenceAudit {
            val seen = mutableSetOf<Long>()
            var highestSeen: Long? = null
            var duplicates = 0
            var reordered = 0

            sequences.forEach { sequence ->
                if (!seen.add(sequence)) {
                    duplicates++
                } else {
                    if (highestSeen != null && sequence < highestSeen!!) reordered++
                    if (highestSeen == null || sequence > highestSeen!!) highestSeen = sequence
                }
            }

            val missing = if (seen.isEmpty()) {
                0
            } else {
                seen.max() - seen.min() + 1 - seen.size
            }
            return RealtimeSequenceAudit(seen.size, duplicates, reordered, missing)
        }
    }
}
