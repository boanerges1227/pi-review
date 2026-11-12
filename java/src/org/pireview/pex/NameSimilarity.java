package org.pireview.pex;

import com.ibm.icu.lang.UCharacter;
import com.ibm.icu.text.Normalizer2;
import java.util.ArrayDeque;

/** Preserve name-v1 supporting evidence; this score never authorizes an identity association. */
public final class NameSimilarity {
    private NameSimilarity() {}

    /** Match Python Unicode15 NFKC, default casefold and whitespace collapsing on copies only. */
    public static String normalize(String input) {
        String folded = UCharacter.foldCase(Normalizer2.getNFKCInstance().normalize(input), true);
        StringBuilder output = new StringBuilder();
        boolean pendingSpace = false;
        for (int cp : folded.codePoints().toArray()) {
            if (UCharacter.isUWhiteSpace(cp) || (cp >= 0x1c && cp <= 0x1f)) {
                pendingSpace = output.length() > 0;
            } else {
                if (pendingSpace) output.append(' ');
                output.appendCodePoint(cp);
                pendingSpace = false;
            }
        }
        return output.toString();
    }

    /** Sum recursively partitioned longest common blocks, using SequenceMatcher's earliest tie order. */
    public static double ratio(String left, String right) {
        int[] a = left.codePoints().toArray(), b = right.codePoints().toArray();
        if (a.length == 0 || b.length == 0) return 0;
        ArrayDeque<int[]> ranges = new ArrayDeque<>();
        ranges.add(new int[]{0, a.length, 0, b.length});
        int matched = 0;
        while (!ranges.isEmpty()) {
            int[] r = ranges.removeLast();
            int bestI = r[0], bestJ = r[2], bestSize = 0;
            int width = r[3] - r[2];
            int[] previous = new int[width + 1];
            for (int i = r[0]; i < r[1]; i++) {
                int[] current = new int[width + 1];
                for (int j = 1; j <= width; j++) {
                    if (a[i] == b[r[2] + j - 1]) {
                        current[j] = previous[j - 1] + 1;
                        if (current[j] > bestSize) {
                            bestSize = current[j];
                            bestI = i - bestSize + 1;
                            bestJ = r[2] + j - bestSize;
                        }
                    }
                }
                previous = current;
            }
            if (bestSize == 0) continue;
            matched += bestSize;
            if (r[0] < bestI && r[2] < bestJ)
                ranges.add(new int[]{r[0], bestI, r[2], bestJ});
            if (bestI + bestSize < r[1] && bestJ + bestSize < r[3])
                ranges.add(new int[]{bestI + bestSize, r[1], bestJ + bestSize, r[3]});
        }
        return 2.0 * matched / (a.length + b.length);
    }
}
