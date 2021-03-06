defmodule DappDemo.Crypto do
  @moduledoc """
  crypto module
  """

  use Bitwise

  @base_recovery_id 27
  @standard_scrypt_n 1 <<< 18
  @standard_scrypt_p 1
  @scrypt_r 8
  @scrypt_dk_len 32

  @doc """
  Keccak-256 hash
  """
  def keccak256(data), do: :keccakf1600.hash(:sha3_256, data)

  @doc """
  string sign to {v, r, s}
  """
  def decode_sign(signature) do
    <<r::binary-size(64), s::binary-size(64), v::binary-size(2)>> = signature
    {String.to_integer(v, 16), String.to_integer(r, 16), String.to_integer(s, 16)}
  end

  def msg_hash(msg) do
    keccak256("\x19Ethereum Signed Message:\n" <> Integer.to_string(String.length(msg)) <> msg)
  end

  @doc """
  get eth address
  """
  def get_eth_addr(public_key) do
    <<_::size(8), key::binary-size(64)>> = Base.decode16!(public_key, case: :mixed)
    <<_::binary-size(12), eth_addr::binary-size(20)>> = keccak256(key)
    "0x" <> Base.encode16(eth_addr, case: :lower)
  end

  @doc """
  get public key from private key
  """
  def eth_privkey_to_pubkey(private_key) do
    {:ok, public_key} =
      Base.decode16!(private_key, case: :mixed) |> :libsecp256k1.ec_pubkey_create(:uncompressed)

    Base.encode16(public_key, case: :lower)
  end

  @doc """
  eth_sign
  """
  @spec eth_sign(String.t(), String.t()) :: String.t()
  def eth_sign(msg, private_key) do
    hash = keccak256(msg)

    {:ok, rs, v} =
      :libsecp256k1.ecdsa_sign_compact(
        hash,
        Base.decode16!(private_key, case: :mixed),
        :default,
        <<>>
      )

    Base.encode16(rs <> <<@base_recovery_id + v>>, case: :lower)
  end

  @doc """
  eth_verify
  return: :ok / :error
  """
  def eth_verify(msg, sign, public_key) do
    hash = keccak256(msg)

    :libsecp256k1.ecdsa_verify_compact(
      hash,
      Base.decode16!(sign, case: :mixed),
      Base.decode16!(public_key, case: :mixed)
    )
  end

  @doc """
  ecRecover
  return: eth address
  """
  @spec eth_recover(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def eth_recover(msg, sign) do
    {v, _r, _s} = decode_sign(sign)
    recovery_id = v - @base_recovery_id
    hash = keccak256(msg)

    case :libsecp256k1.ecdsa_recover_compact(
           hash,
           Base.decode16!(sign, case: :mixed),
           :uncompressed,
           recovery_id
         ) do
      {:ok, public_key} ->
        addr = public_key |> Base.encode16(case: :lower) |> get_eth_addr()
        {:ok, addr}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  encrypt private key to keystore
  """
  def encrypt_private_key(private_key, auth) do
    public_key = eth_privkey_to_pubkey(private_key)
    address = get_eth_addr(public_key)

    salt = :crypto.strong_rand_bytes(32)

    derived_key =
      :erlscrypt.scrypt(
        auth,
        salt,
        @standard_scrypt_n,
        @scrypt_r,
        @standard_scrypt_p,
        @scrypt_dk_len
      )

    <<encrypt_key::binary-size(16), key::binary-size(16)>> = derived_key
    key_bytes = private_key |> Base.decode16!(case: :mixed) |> Binary.pad_leading(32)
    iv = :crypto.strong_rand_bytes(16)
    cipher_text = aes_CTRXOR(encrypt_key, key_bytes, iv)
    mac = keccak256(key <> cipher_text)

    %{
      address: address,
      crypto: %{
        cipher: "aes-128-ctr",
        ciphertext: Base.encode16(cipher_text, case: :lower),
        cipherparams: %{
          iv: Base.encode16(iv, case: :lower)
        },
        kdf: "scrypt",
        kdfparams: %{
          n: @standard_scrypt_n,
          r: @scrypt_r,
          p: @standard_scrypt_p,
          dklen: @scrypt_dk_len,
          salt: Base.encode16(salt, case: :lower)
        },
        mac: Base.encode16(mac, case: :lower)
      },
      id: UUID.uuid4(),
      version: 3
    }
  end

  @doc """
  get private key from keystore
  """
  def decrypt_keystore(keystore, auth) do
    private_key = decrpt_key(keystore, auth, keystore.version)

    if private_key != :error do
      {:ok, Base.encode16(private_key, case: :lower)}
    else
      :error
    end
  rescue
    _ ->
      :error
  end

  defp decrpt_key(%{} = keystore, auth, version) do
    mac = Base.decode16!(keystore[:crypto][:mac], case: :mixed)
    iv = Base.decode16!(keystore[:crypto][:cipherparams].iv, case: :mixed)
    cipher_text = Base.decode16!(keystore[:crypto][:ciphertext], case: :mixed)

    derived_key = get_kdf_key(keystore[:crypto], auth)

    # check mac
    calc_mac = keccak256(String.slice(derived_key, 16, 16) <> cipher_text)

    if calc_mac == mac do
      if version == 1 do
        # TODO: need test
        aes_CBC_Decrypt(
          String.slice(derived_key, 0, 16) |> keccak256() |> String.slice(0, 16),
          cipher_text,
          iv
        )
      else
        aes_CTRXOR(String.slice(derived_key, 0, 16), cipher_text, iv)
      end
    else
      :error
    end
  end

  defp get_kdf_key(crypto, auth) do
    salt = Base.decode16!(crypto.kdfparams.salt, case: :mixed)
    dk_len = crypto.kdfparams.dklen

    if crypto.kdf == "scrypt" do
      n = crypto.kdfparams.n
      r = crypto.kdfparams.r
      p = crypto.kdfparams.p

      :erlscrypt.scrypt(auth, salt, n, r, p, dk_len)
    else
      c = crypto.kdfparams.c

      {:ok, key} = :pbkdf2.pbkdf2(:sha256, auth, salt, c, dk_len)
      key
    end
  end

  defp aes_CTRXOR(key, cipher_text, iv) do
    state = :crypto.stream_init(:aes_ctr, key, iv)
    {_new_state, plain_text} = :crypto.stream_decrypt(state, cipher_text)
    plain_text
  end

  defp aes_CBC_Decrypt(key, cipher_text, iv) do
    :crypto.block_decrypt(:aes_cbc, key, iv, cipher_text)
  end
end
