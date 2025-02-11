defmodule SignDict.User do
  require SignDictWeb.Gettext

  import Exgravatar

  use SignDictWeb, :model
  use Arc.Ecto.Schema

  alias Ecto.Changeset
  alias SignDictWeb.Avatar
  alias SignDictWeb.Gettext
  alias SignDict.Repo
  alias SignDict.User

  @all_flags ~w(recording)
  @roles ~w(user admin editor)
  @subscriber Application.get_env(:sign_dict, :newsletter)[:subscriber]

  @primary_key {:id, SignDict.Permalink, autogenerate: true}
  schema "users" do
    field(:email, :string)

    field(:want_newsletter, :boolean, virtual: true)

    field(:password, :string, virtual: true)
    field(:password_confirmation, :string, virtual: true)
    field(:password_hash, :string)

    field(:name, :string)
    field(:biography, :string)

    field(:role, :string)

    field(:password_reset_token, :string)
    field(:password_reset_unencrypted, :string, virtual: true)

    field(:avatar, SignDictWeb.Avatar.Type)

    field(:unconfirmed_email, :string)
    field(:confirmation_token, :string)
    field(:confirmation_token_unencrypted, :string, virtual: true)
    field(:confirmed_at, :utc_datetime)
    field(:confirmation_sent_at, :utc_datetime)

    field(:flags, {:array, :string})

    field(:locale, :string)

    has_many(:videos, SignDict.Video)

    timestamps()
  end

  def roles, do: @roles

  def all_flags, do: @all_flags

  def avatar_url(user)

  def avatar_url(user = %SignDict.User{avatar: avatar}) when avatar != nil do
    Avatar.url({avatar, user}, :thumb)
  end

  def avatar_url(user = %SignDict.User{email: email}) when email != nil do
    gravatar_url(user.email, s: 256)
  end

  def avatar_url(_user), do: ""

  def admin?(struct) do
    struct.role == "admin"
  end

  def all_editors do
    User
    |> where([c], c.role == "editor")
    |> Repo.all()
  end

  def changeset(user, params \\ %{}) do
    user
    |> cast(params, [:email, :name, :biography, :password, :password_confirmation, :locale])
    |> cast_attachments(params, [:avatar])
    |> validate_required([:email, :name])
    |> validate_email
    |> validate_password_if_present
    |> confirm_email_change
  end

  def register_changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :email,
      :password,
      :password_confirmation,
      :name,
      :biography,
      :want_newsletter
    ])
    |> validate_required([:email, :name, :password, :password_confirmation])
    |> validate_email
    |> validate_password
    |> confirm_email_change
  end

  def confirm_email_change(changeset) do
    cond do
      email_already_used?(changeset) ->
        add_error(changeset, :email, Gettext.gettext("already used"))

      changeset.valid? && Changeset.fetch_change(changeset, :email) != :error ->
        do_confirm_email_change(changeset)

      true ->
        changeset
    end
  end

  defp do_confirm_email_change(changeset) do
    {unencrypted_token, encrypted_token} = generate_token()

    changeset
    |> put_change(:unconfirmed_email, changeset.changes[:email])
    |> put_change(:confirmation_token, encrypted_token)
    |> put_change(:confirmation_token_unencrypted, unencrypted_token)
    |> delete_change(:email)
  end

  defp email_already_used?(changeset) do
    {_source, user_id} = fetch_field(changeset, :id)
    {_source, email} = fetch_field(changeset, :email)
    do_email_already_used?(user_id, email)
  end

  defp do_email_already_used?(user_id, email) when is_nil(user_id) and is_nil(email) do
    false
  end

  defp do_email_already_used?(user_id, email) when is_nil(user_id) do
    count =
      User
      |> where([user], user.email == ^email or user.unconfirmed_email == ^email)
      |> Repo.aggregate(:count, :id)

    count > 0
  end

  defp do_email_already_used?(user_id, email) do
    count =
      User
      |> where(
        [user],
        (user.id != ^user_id and user.email == ^email) or user.unconfirmed_email == ^email
      )
      |> Repo.aggregate(:count, :id)

    count > 0
  end

  def confirm_email_changeset(user, params) do
    user
    |> cast(params, [:confirmation_token_unencrypted])
    |> put_change(:email, user.unconfirmed_email)
    |> put_change(:unconfirmed_email, nil)
    |> put_change(:confirmed_at, DateTime.truncate(DateTime.utc_now(), :second))
    |> validate_email
    |> validate_token(:confirmation_token, :confirmation_token_unencrypted)
  end

  def admin_changeset(user, params \\ %{}) do
    user
    |> cast(params, [:email, :name, :biography, :password, :password_confirmation, :role, :flags])
    |> cast_attachments(params, [:avatar])
    |> validate_required([:email, :name])
    |> validate_email
    |> clean_flags_if_empty(params)
    |> validate_password_if_present
  end

  defp clean_flags_if_empty(changeset, params) do
    if params != %{} && get_change(changeset, :flags, []) == [] do
      changeset
      |> put_change(:flags, [])
    else
      changeset
    end
  end

  def confirm_sent_at_changeset(user) do
    user
    |> cast(%{confirmation_sent_at: DateTime.truncate(DateTime.utc_now(), :second)}, [
      :confirmation_sent_at
    ])
  end

  def create_reset_password_changeset(struct) do
    {unencrypted_token, encrypted_token} = generate_token()

    struct
    |> change
    |> put_change(:password_reset_unencrypted, unencrypted_token)
    |> put_change(:password_reset_token, encrypted_token)
  end

  def reset_password_changeset(struct, params) do
    struct
    |> cast(params, [:password, :password_confirmation, :password_reset_unencrypted])
    |> validate_required([:password, :password_confirmation])
    |> validate_token(:password_reset_token, :password_reset_unencrypted)
    |> validate_password
  end

  defp validate_token(%{valid?: false} = changeset, _field_encrypted, _field_unencrypted),
    do: changeset

  defp validate_token(%{valid?: true} = changeset, field_encrypted, field_unencrypted) do
    {:ok, reset_unencrypted} = Changeset.fetch_change(changeset, field_unencrypted)
    {_, reset_encrypted} = Changeset.fetch_field(changeset, field_encrypted)
    token_matches = Bcrypt.verify_pass(reset_unencrypted, reset_encrypted)
    do_validate_token(token_matches, changeset, field_encrypted)
  end

  defp do_validate_token(true, changeset, _field_encrypted), do: changeset

  defp do_validate_token(false, changeset, field_encrypted) do
    Changeset.add_error(changeset, field_encrypted, "invalid")
  end

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end

  defp validate_password_if_present(changeset) do
    if get_change(changeset, :password, "") != "" ||
         get_change(changeset, :password_confirmation, "") != "" ||
         changeset.data.password_hash == nil do
      changeset
      |> validate_required([:password, :password_confirmation])
      |> validate_password
    else
      changeset
    end
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8)
    |> validate_confirmation(:password)
    |> hash_password()
  end

  defp hash_password(%{valid?: false} = changeset), do: changeset

  defp hash_password(%{valid?: true} = changeset) do
    hashed_password =
      changeset
      |> get_field(:password)
      |> Bcrypt.hash_pwd_salt()

    changeset
    |> put_change(:password_hash, hashed_password)
  end

  defp generate_token do
    unencrypted_token = SecureRandom.urlsafe_base64(32)
    {unencrypted_token, Bcrypt.hash_pwd_salt(unencrypted_token)}
  end

  def subscribe_to_newsletter(user) do
    @subscriber.add_member("f96556b89f", :subscribed, user.email || user.unconfirmed_email, %{
      "FULL_NAME" => user.name
    })
  end

  def has_flag?(user, _flag) when is_nil(user) do
    false
  end

  def has_flag?(user, flag) do
    Enum.member?(user.flags || [], flag)
  end
end

defimpl Phoenix.Param, for: SignDict.User do
  def to_param(%{name: name, id: id}) do
    SignDict.Permalink.to_permalink(id, name)
  end
end

defimpl SignDict.Serializer, for: SignDict.User do
  alias SignDict.User

  def to_map(user) do
    %{
      user: %{
        id: user.id,
        name: user.name,
        email: user.email || user.unconfirmed_email,
        avatar: User.avatar_url(user)
      }
    }
  end
end
