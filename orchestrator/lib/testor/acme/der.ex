defmodule Testor.Acme.DER do
  @moduledoc """
  The few DER encodings a certificate signing request needs (PKCS #10, RFC 2986), so testor
  builds one without a dependency. `csr/2` is the request for a set of DNS names.
  """
  import Bitwise

  @ec_public_key {1, 2, 840, 10045, 2, 1}
  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @rsa_sha256 {1, 2, 840, 113_549, 1, 1, 11}
  @common_name {2, 5, 4, 3}
  @extension_request {1, 2, 840, 113_549, 1, 9, 14}
  @subject_alt_name {2, 5, 29, 17}

  @doc """
  A DER-encoded CSR for `domains` (the first is the subject's common name when it fits in 64
  characters; all are in the subject alternative names), signed with `key` (an `ECPrivateKey`
  on P-256 or an `RSAPrivateKey` record).
  """
  def csr([first | _] = domains, key) do
    subject =
      if byte_size(first) <= 64,
        do: sequence([set([sequence([oid(@common_name), utf8(first)])])]),
        else: sequence([])

    names = sequence(Enum.map(domains, &tagged(0x82, &1)))
    extensions = sequence([sequence([oid(@subject_alt_name), octets(names)])])
    attributes = tagged(0xA0, sequence([oid(@extension_request), set([extensions])]))
    info = sequence([integer(0), subject, public_key_info(key), attributes])
    {algorithm, signature} = sign(info, key)
    sequence([info, algorithm, bits(signature)])
  end

  defp public_key_info({:ECPrivateKey, _, _, {:namedCurve, @p256}, public, _}),
    do: sequence([sequence([oid(@ec_public_key), oid(@p256)]), bits(public)])

  defp public_key_info({:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _}) do
    rsa = :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, n, e})
    sequence([sequence([oid(@rsa_encryption), null()]), bits(rsa)])
  end

  defp sign(info, {:ECPrivateKey, _, _, _, _, _} = key),
    do: {sequence([oid(@ecdsa_sha256)]), :public_key.sign(info, :sha256, key)}

  defp sign(info, key), do: {sequence([oid(@rsa_sha256), null()]), :public_key.sign(info, :sha256, key)}

  @doc false
  def sequence(items), do: tagged(0x30, IO.iodata_to_binary(items))
  def set(items), do: tagged(0x31, IO.iodata_to_binary(items))
  def octets(bytes), do: tagged(0x04, bytes)
  def bits(bytes), do: tagged(0x03, <<0>> <> bytes)
  def utf8(text), do: tagged(0x0C, text)
  def null, do: <<0x05, 0>>

  def integer(n) when n >= 0 do
    bytes = :binary.encode_unsigned(n)
    bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
    tagged(0x02, bytes)
  end

  def oid(oid) do
    [a, b | rest] = Tuple.to_list(oid)
    tagged(0x06, IO.iodata_to_binary([40 * a + b | Enum.map(rest, &base128/1)]))
  end

  defp base128(n) when n < 128, do: <<n>>

  defp base128(n) do
    [last | higher] = digits(n, [])
    IO.iodata_to_binary(Enum.map(Enum.reverse(higher), &(&1 ||| 0x80)) ++ [last])
  end

  defp digits(0, acc), do: Enum.reverse(acc)
  defp digits(n, acc), do: digits(div(n, 128), [rem(n, 128) | acc])

  def tagged(tag, bytes), do: <<tag>> <> der_length(byte_size(bytes)) <> bytes

  defp der_length(n) when n < 128, do: <<n>>

  defp der_length(n) do
    bytes = :binary.encode_unsigned(n)
    <<0x80 + byte_size(bytes)>> <> bytes
  end
end
