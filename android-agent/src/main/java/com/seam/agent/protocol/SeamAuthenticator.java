package com.seam.agent.protocol;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Unified Mutual Challenge-Response Authenticator for SEAM transports (USB and Wi-Fi).
 *
 * <p>Neither USB nor Wi-Fi connections are trusted without passing this mutual HMAC-SHA256
 * handshake using a 256-bit session/pairing key:
 * <ol>
 *   <li><b>Server Challenge (38 bytes):</b> {@code "SEAM"(4B) || version(1B) || transport(1B) || serverNonce(32B)}</li>
 *   <li><b>Client Response (68 bytes):</b> {@code "SEAM"(4B) || clientNonce(32B) || clientHmac(32B)}
 *       where {@code clientHmac = HMAC-SHA256(key, "SEAM-CLIENT-AUTH-v1" || serverNonce || clientNonce)}</li>
 *   <li><b>Server Ack (41 bytes):</b> {@code status(1B) || sessionId(8B, le) || serverHmac(32B)}
 *       where {@code serverHmac = HMAC-SHA256(key, "SEAM-SERVER-AUTH-v1" || clientNonce || serverNonce || sessionId)}</li>
 * </ol>
 */
public final class SeamAuthenticator {

    public static final int NONCE_SIZE = 32;
    public static final int HMAC_SIZE  = 32;

    private static final byte[] CLIENT_DOMAIN = "SEAM-CLIENT-AUTH-v1".getBytes(StandardCharsets.UTF_8);
    private static final byte[] SERVER_DOMAIN = "SEAM-SERVER-AUTH-v1".getBytes(StandardCharsets.UTF_8);
    private static final byte[] UDP_DOMAIN    = "SEAM-UDP-AUTH-v1".getBytes(StandardCharsets.UTF_8);

    /** Size in bytes of the truncated HMAC-SHA256 tag attached to each UDP fast-path datagram. */
    public static final int UDP_TAG_SIZE = 16;
    /** Total size in bytes of an authenticated SEAM UDP fast-path datagram (26B header/payload + 16B tag). */
    public static final int UDP_PACKET_SIZE = 42;

    private final byte[] secretKey;
    private final SecureRandom secureRandom = new SecureRandom();

    public SeamAuthenticator(byte[] secretKey) {
        if (secretKey == null || secretKey.length < 16) {
            throw new IllegalArgumentException("Authentication key must be at least 16 bytes");
        }
        this.secretKey = secretKey.clone();
    }

    /**
     * Parses a 64-character hexadecimal key string into a 32-byte key array.
     */
    public static byte[] parseHexKey(String hex) {
        String clean = hex.trim();
        if (clean.length() % 2 != 0 || clean.length() < 32) {
            throw new IllegalArgumentException("Invalid hex key length: " + clean.length());
        }
        int len = clean.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            int hi = Character.digit(clean.charAt(i * 2), 16);
            int lo = Character.digit(clean.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) {
                throw new IllegalArgumentException("Non-hex character in auth key");
            }
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    /**
     * Executes the server side of the mutual authentication handshake.
     *
     * @return The authenticated 64-bit session ID if verification succeeds.
     * @throws IOException If the peer fails authentication or the stream closes.
     */
    public long authenticateServerSocket(
            DataInputStream in,
            DataOutputStream out,
            byte transportType
    ) throws IOException {
        byte[] serverNonce = new byte[NONCE_SIZE];
        secureRandom.nextBytes(serverNonce);

        // 1. Send 38-byte Server Challenge
        out.write(SeamProtocol.MAGIC);
        out.writeByte(SeamProtocol.PROTOCOL_VERSION);
        out.writeByte(transportType);
        out.write(serverNonce);
        out.flush();

        // 2. Read 68-byte Client Response
        byte[] clientMagic = new byte[4];
        in.readFully(clientMagic);
        if (!Arrays.equals(clientMagic, SeamProtocol.MAGIC)) {
            throw new IOException("Invalid protocol magic in client auth response");
        }

        byte[] clientNonce = new byte[NONCE_SIZE];
        in.readFully(clientNonce);

        byte[] clientHmac = new byte[HMAC_SIZE];
        in.readFully(clientHmac);

        // 3. Verify Client HMAC in constant time
        byte[] expectedClientHmac = computeHmac(CLIENT_DOMAIN, serverNonce, clientNonce, null);
        if (!MessageDigest.isEqual(clientHmac, expectedClientHmac)) {
            out.writeByte(SeamProtocol.AUTH_STATUS_FAILED);
            out.writeLong(0L);
            out.write(new byte[HMAC_SIZE]);
            out.flush();
            throw new IOException("Client HMAC authentication failed");
        }

        // 4. Generate 64-bit session ID and send 41-byte Server Ack
        long sessionId = secureRandom.nextLong();
        if (sessionId == 0L) {
            sessionId = 1L;
        }
        byte[] sessionIdLe = new byte[8];
        ByteBuffer.wrap(sessionIdLe).order(ByteOrder.LITTLE_ENDIAN).putLong(sessionId);

        byte[] serverHmac = computeHmac(SERVER_DOMAIN, clientNonce, serverNonce, sessionIdLe);

        out.writeByte(SeamProtocol.AUTH_STATUS_OK);
        out.write(sessionIdLe);
        out.write(serverHmac);
        out.flush();

        return sessionId;
    }

    /**
     * Verifies the 16-byte truncated HMAC-SHA256 authentication tag on an incoming 42-byte UDP
     * fast-path datagram ({@code bytes[0..25]} signed, {@code bytes[26..41]} tag).
     */
    public boolean verifyUdpDatagram(byte[] packet, int offset) {
        if (packet == null || packet.length - offset < UDP_PACKET_SIZE) {
            return false;
        }
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secretKey, "HmacSHA256"));
            mac.update(UDP_DOMAIN);
            mac.update(packet, offset, 26);
            byte[] fullHmac = mac.doFinal();

            int diff = 0;
            for (int i = 0; i < UDP_TAG_SIZE; i++) {
                diff |= (fullHmac[i] ^ packet[offset + 26 + i]) & 0xFF;
            }
            return diff == 0;
        } catch (GeneralSecurityException e) {
            return false;
        }
    }

    /**
     * Signs a 42-byte outbound UDP datagram in-place, writing the 16-byte tag at {@code offset + 26}.
     */
    public void signUdpDatagram(byte[] packet, int offset) throws IOException {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secretKey, "HmacSHA256"));
            mac.update(UDP_DOMAIN);
            mac.update(packet, offset, 26);
            byte[] fullHmac = mac.doFinal();
            System.arraycopy(fullHmac, 0, packet, offset + 26, UDP_TAG_SIZE);
        } catch (GeneralSecurityException e) {
            throw new IOException("UDP HMAC signing failed", e);
        }
    }

    private byte[] computeHmac(byte[] domain, byte[] firstNonce, byte[] secondNonce, byte[] extra) throws IOException {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secretKey, "HmacSHA256"));
            mac.update(domain);
            mac.update(firstNonce);
            mac.update(secondNonce);
            if (extra != null) {
                mac.update(extra);
            }
            return mac.doFinal();
        } catch (GeneralSecurityException e) {
            throw new IOException("HmacSHA256 computation failed", e);
        }
    }
}
