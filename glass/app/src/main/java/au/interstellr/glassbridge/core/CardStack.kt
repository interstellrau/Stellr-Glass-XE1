package au.interstellr.glassbridge.core

/**
 * The card stack behind the card screen: newest first, at most [max] cards, TTL-pruned.
 * A card whose id is already in the stack is replaced and moves to the front.
 *
 * Not thread-safe: GlassState owns one and uses it on the main thread only. The pinned nav
 * card is not part of the stack (GlassState holds a [NavState] separately).
 */
class CardStack @JvmOverloads constructor(val max: Int = MAX_CARDS) {
    private val list = ArrayList<Card>()
    private val shown = HashSet<String>()

    val size: Int get() = list.size
    val isEmpty: Boolean get() = list.isEmpty()

    /** A snapshot, newest first. */
    val cards: List<Card> get() = ArrayList(list)

    operator fun get(index: Int): Card = list[index]

    /** Index of the card with [id], or -1. */
    fun indexOf(id: String?): Int {
        if (id == null) return -1
        for (i in list.indices) if (list[i].id == id) return i
        return -1
    }

    fun find(id: String?): Card? = indexOf(id).let { if (it >= 0) list[it] else null }

    /**
     * Adds [card] at the front, replacing any card with the same id, and drops the oldest
     * cards beyond [max]. Returns true if the id wasn't in the stack before. A replaced
     * card counts as not yet shown (see [markShown]).
     */
    fun put(card: Card): Boolean {
        val old = indexOf(card.id)
        if (old >= 0) list.removeAt(old)
        list.add(0, card)
        shown.remove(card.id)
        while (list.size > max) {
            val dropped = list.removeAt(list.size - 1)
            shown.remove(dropped.id)
        }
        return old < 0
    }

    /** Removes the card with [id]; returns it, or null if it wasn't there. */
    fun remove(id: String?): Card? {
        val i = indexOf(id)
        if (i < 0) return null
        shown.remove(id)
        return list.removeAt(i)
    }

    /** Removes expired cards; returns true if any were removed. */
    fun prune(now: Long): Boolean {
        var changed = false
        val it = list.iterator()
        while (it.hasNext()) {
            val c = it.next()
            if (c.isExpired(now)) {
                it.remove()
                shown.remove(c.id)
                changed = true
            }
        }
        return changed
    }

    fun clear() {
        list.clear()
        shown.clear()
    }

    /**
     * Marks the card as rendered. Returns true the first time for this card (send
     * `ack shown` then), false after that.
     */
    fun markShown(id: String): Boolean {
        if (indexOf(id) < 0) return false
        return shown.add(id)
    }

    /**
     * Where the view should be after the stack changed: the index of [currentId] if that card
     * is still there, otherwise [previousIndex] clamped into range (0 for an empty stack).
     */
    fun positionAfterChange(currentId: String?, previousIndex: Int): Int {
        val i = indexOf(currentId)
        if (i >= 0) return i
        if (list.isEmpty()) return 0
        return Math.max(0, Math.min(previousIndex, list.size - 1))
    }

    companion object {
        const val MAX_CARDS = 25
    }
}
