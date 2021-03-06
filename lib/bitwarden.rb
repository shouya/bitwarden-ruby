#
# Copyright (c) 2017 joshua stein <jcs@jcs.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

require "jwt"
require "pbkdf2"
require "openssl"

class Bitwarden
  class InvalidCipherString < RuntimeError; end

  # convenience methods for hashing/encryption/decryption that the apps do,
  # just so we can test against
  class << self
    # pbkdf2 stretch a password+salt
    def makeKey(password, salt)
      PBKDF2.new(:password => password, :salt => salt,
        :iterations => 5000, :hash_function => OpenSSL::Digest::SHA256,
        :key_length => (256 / 8)).bin_string
    end

    # encrypt random bytes with a key to make new encryption key
    def makeEncKey(key)
      pt = OpenSSL::Random.random_bytes(64)
      iv = OpenSSL::Random.random_bytes(16)

      cipher = OpenSSL::Cipher.new "AES-256-CBC"
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      ct = cipher.update(pt)
      ct << cipher.final

      CipherString.new(
        CipherString::TYPE_AESCBC256_B64,
        Base64.strict_encode64(iv),
        Base64.strict_encode64(ct),
      ).to_s
    end

    # base64-encode a wrapped, stretched password+salt for signup/login
    def hashPassword(password, salt)
      key = makeKey(password, salt)
      Base64.strict_encode64(PBKDF2.new(:password => key, :salt => password,
        :iterations => 1, :key_length => 256/8,
        :hash_function => OpenSSL::Digest::SHA256).bin_string)
    end

    # encrypt+mac a value with a key and mac key and random iv, return a
    # CipherString of it
    def encrypt(pt, key, macKey)
      iv = OpenSSL::Random.random_bytes(16)

      cipher = OpenSSL::Cipher.new "AES-256-CBC"
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      ct = cipher.update(pt)
      ct << cipher.final

      mac = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey,
        iv + ct)

      CipherString.new(
        CipherString::TYPE_AESCBC256_HMACSHA256_B64,
        Base64.strict_encode64(iv),
        Base64.strict_encode64(ct),
        Base64.strict_encode64(mac),
      )
    end

    # compare two hmacs, with double hmac verification
    # https://www.nccgroup.trust/us/about-us/newsroom-and-events/blog/2011/february/double-hmac-verification/
    def macsEqual(macKey, mac1, mac2)
      hmac1 = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, mac1)
      hmac2 = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), macKey, mac2)
      return hmac1 == hmac2
    end

    # decrypt a CipherString and return plaintext
    def decrypt(str, key, macKey)
      c = CipherString.parse(str)
      iv = Base64.decode64(c.iv)
      ct = Base64.decode64(c.ct)
      mac = c.mac ? Base64.decode64(c.mac) : nil

      case c.type
      when CipherString::TYPE_AESCBC256_B64
        cipher = OpenSSL::Cipher.new "AES-256-CBC"
        cipher.decrypt
        cipher.iv = iv
        cipher.key = key
        pt = cipher.update(ct)
        pt << cipher.final
        return pt

      when CipherString::TYPE_AESCBC256_HMACSHA256_B64
        cmac = OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"),
          macKey, iv + ct)
        if !self.macsEqual(macKey, mac, cmac)
          raise "invalid mac"
        end

        cipher = OpenSSL::Cipher.new "AES-256-CBC"
        cipher.decrypt
        cipher.iv = iv
        cipher.key = key
        pt = cipher.update(ct)
        pt << cipher.final
        return pt

      else
        raise "TODO implement #{c.type}"
      end
    end
  end

  class CipherString
    TYPE_AESCBC256_B64                     = 0
    TYPE_AESCBC128_HMACSHA256_B64          = 1
    TYPE_AESCBC256_HMACSHA256_B64          = 2
    TYPE_RSA2048_OAEPSHA256_B64            = 3
    TYPE_RSA2048_OAEPSHA1_B64              = 4
    TYPE_RSA2048_OAEPSHA256_HMACSHA256_B64 = 5
    TYPE_RSA2048_OAEPSHA1_HMACSHA256_B64   = 6

    attr_reader :type, :iv, :ct, :mac

    def self.parse(str)
      if !(m = str.to_s.match(/\A(\d)\.([^|]+)\|(.+)\z/))
        raise InvalidCipherString "invalid CipherString: #{str.inspect}"
      end

      type = m[1].to_i
      iv = m[2]
      ct, mac = m[3].split("|", 2)
      CipherString.new(type, iv, ct, mac)
    end

    def initialize(type, iv, ct, mac = nil)
      @type = type
      @iv = iv
      @ct = ct
      @mac = mac
    end

    def to_s
      [ self.type.to_s + "." + self.iv, self.ct, self.mac ].
        reject{|p| !p }.
        join("|")
    end
  end

  class Token
    class << self
      KEY = "#{APP_ROOT}/db/jwt-rsa.key"

      attr_reader :rsa

      # load or create RSA pair used for JWT signing
      def load_keys
        if File.exist?(KEY)
          @rsa = OpenSSL::PKey::RSA.new File.read(KEY)
        else
          @rsa = OpenSSL::PKey::RSA.generate 2048

          f = File.new(KEY, File::CREAT|File::TRUNC|File::RDWR, 0600)
          f.write @rsa.to_pem
          f.write @rsa.public_key.to_pem
          f.close
        end
      end

      def sign(payload)
        JWT.encode(payload, @rsa, "RS256")
      end
    end
  end
end
