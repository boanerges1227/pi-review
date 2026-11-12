package org.pireview.pex;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.intersystems.enslib.pex.BusinessOperation;
import com.intersystems.jdbc.IRISObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/** Execute bounded name similarity inside the real Java PEX external language server. */
public final class NameSimilarityOperation extends BusinessOperation {
    private static final ObjectMapper JSON = new ObjectMapper()
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);

    /** No external services, model credentials or mutable patient records are needed. */
    @Override public void OnInit() {}

    /** The operation owns no persistent resources. */
    @Override public void OnTearDown() {}

    /** Accept native IRIS messages and return a native reply without exposing private exceptions. */
    @Override public Object OnMessage(Object request) throws Exception {
        IRISObject input = (IRISObject) request;
        IRISObject reply = (IRISObject) input.iris.classMethodObject("PI.Reply", "%New");
        reply.set("Payload", evaluate(input.getString("Payload")));
        return reply;
    }

    /** Share strict input validation between actual PEX dispatch and the parity harness. */
    public static String evaluate(String raw) throws Exception {
        Map<String, Object> result = new LinkedHashMap<>();
        try {
            if (raw == null || raw.length() > 12000) throw new IllegalArgumentException("INVALID_NAME_INPUT");
            JsonNode data = JSON.readTree(raw);
            if (data == null || !data.isObject() || !data.path("left").isTextual() || !data.path("right").isTextual())
                throw new IllegalArgumentException("INVALID_NAME_INPUT");
            String left = data.get("left").asText(), right = data.get("right").asText();
            if (left.codePointCount(0, left.length()) > 500 || right.codePointCount(0, right.length()) > 500)
                throw new IllegalArgumentException("FIELD_TOO_LONG");
            String a = NameSimilarity.normalize(left), b = NameSimilarity.normalize(right);
            boolean comparable = !a.isEmpty() && !b.isEmpty();
            result.put("comparable", comparable);
            result.put("score", comparable ? NameSimilarity.ratio(a, b) : 0.0);
            result.put("algorithmVersion", "name-v1");
            result.put("transport", "pex");
            result.put("implementation", "java");
        } catch (IllegalArgumentException e) {
            result.clear();
            result.put("code", "FIELD_TOO_LONG".equals(e.getMessage()) ? "FIELD_TOO_LONG" : "INVALID_NAME_INPUT");
        } catch (com.fasterxml.jackson.core.JsonProcessingException e) {
            result.clear();
            result.put("code", "INVALID_NAME_INPUT");
        } catch (Exception e) {
            result.clear();
            result.put("code", "PEX_NAME_UNAVAILABLE");
        }
        return JSON.writeValueAsString(result);
    }

    /** Read JSON lines for deterministic tests; this entry point is not a network service. */
    public static void main(String[] args) throws Exception {
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            for (String line; (line = input.readLine()) != null;) System.out.println(evaluate(line));
        }
    }
}
