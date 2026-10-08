import uuid
from datetime import date, datetime, timezone

from pydantic import BaseModel, ConfigDict, EmailStr, Field, computed_field, field_validator, model_validator

from app.models.user import AuthProvider, UserRole


class UserRegister(BaseModel):
    """Payload for POST /auth/register — mirrors the 3-step Flutter form."""

    # Step 1
    full_name: str = Field(min_length=1, max_length=150)
    email: EmailStr

    # Step 2
    password: str = Field(min_length=8, max_length=128)

    # Role
    role: UserRole

    # Step 3 — required only when role == photographer
    studio_name: str | None = None
    studio_address: str | None = None
    business_type: str | None = None

    agreed_to_terms: bool

    @model_validator(mode="after")
    def check_terms_and_studio(self) -> "UserRegister":
        if not self.agreed_to_terms:
            raise ValueError("You must agree to the Terms & Conditions")
        if self.role == UserRole.photographer and not self.studio_name:
            raise ValueError("studio_name is required for photographers")
        if not any(ch.isdigit() for ch in self.password):
            raise ValueError("Password must include at least one number")
        return self


class UserLogin(BaseModel):
    email: EmailStr
    password: str
    # Optional: only needed to disambiguate when this email is
    # registered under BOTH roles (see auth.py's login()). If omitted
    # and the email maps to exactly one account, login proceeds as
    # before; if it maps to two, the backend asks the client to specify.
    role: UserRole | None = None


class SocialLoginRequest(BaseModel):
    """Payload for POST /auth/social-login — Sign in with Google / Sign
    in with Apple. `id_token` is the provider's signed ID token (Google)
    or identity token (Apple); the backend verifies it against the
    provider's own public keys in `core/social_auth.py` rather than
    trusting anything in this request body except which provider to
    check it against.

    `role` is required and works exactly like the Role Selection screen
    feeding into email Register: the same Google/Apple account can back
    a separate Client row and a separate Studio row, one per role, same
    as email/password accounts (`uq_users_email_role`).

    `full_name` is optional and only ever meaningful on first sign-up —
    Apple's identity token never carries a name at all (Apple hands the
    given/family name to the client once, out-of-band, on the very
    first authorization only), so the app passes it through here
    instead. Google's token does carry a name, used as a fallback when
    this field is omitted.
    """

    provider: AuthProvider
    id_token: str
    role: UserRole | None = None
    full_name: str | None = Field(default=None, max_length=150)

    @field_validator("provider")
    @classmethod
    def _provider_must_be_social(cls, value: AuthProvider) -> AuthProvider:
        if value == AuthProvider.local:
            raise ValueError("provider must be 'google' or 'apple'")
        return value


class UserCompleteProfile(BaseModel):
    """Payload for PUT /auth/complete-profile — the final onboarding step.

    `studio_name` / `specializations` are only required when the
    authenticated user's role is photographer; that's enforced in the
    route against `current_user.role`, not a role field here, since the
    access token already carries the role.
    """

    full_name: str = Field(min_length=1, max_length=150)
    country: str | None = Field(default=None, max_length=100)
    state: str | None = Field(default=None, max_length=100)
    city: str | None = Field(default=None, max_length=100)
    address: str | None = Field(default=None, max_length=255)
    bio: str | None = Field(default=None, max_length=500)

    # Studio business details (photographer role only)
    studio_name: str | None = Field(default=None, max_length=150)
    specializations: list[str] | None = None


class FCMTokenUpdate(BaseModel):
    fcm_token: str | None = None


class UserUpdate(BaseModel):
    """Generic partial profile-update payload (all fields optional, unset
    fields left untouched) — for a future "edit profile" endpoint. Distinct
    from `UserCompleteProfile`, which is the one-time onboarding step and
    requires `full_name`.
    """

    full_name: str | None = Field(default=None, min_length=1, max_length=150)
    country: str | None = Field(default=None, max_length=100)
    state: str | None = Field(default=None, max_length=100)
    city: str | None = Field(default=None, max_length=100)
    address: str | None = Field(default=None, max_length=255)
    bio: str | None = Field(default=None, max_length=500)

    # Studio's own street address (photographer role only) — distinct
    # from `address` above, which is the person's own address and is
    # shared by both roles. Was previously only settable once, at
    # registration (`UserRegister.studio_address`); wired up here so
    # it's editable afterward too, same as `specializations` was.
    studio_address: str | None = Field(default=None, max_length=255)

    # Studio profile fields (Task 3) — meaningful only for photographer
    # ("Studio") accounts; a future edit-profile endpoint is expected to
    # ignore/reject these for client accounts. All optional/nullable.
    year_established: int | None = None
    team_size: int | None = None
    service_areas: list[str] | None = None
    specializations: list[str] | None = None
    studio_type: str | None = Field(default=None, max_length=100)
    experience_years: int | None = None
    languages: list[str] | None = None
    equipment_highlights: str | None = None
    pricing_min: float | None = None
    pricing_max: float | None = None
    package_details: str | None = None
    availability_days: list[str] | None = None
    instagram_url: str | None = Field(default=None, max_length=500)
    facebook_url: str | None = Field(default=None, max_length=500)
    youtube_url: str | None = Field(default=None, max_length=500)
    pinterest_url: str | None = Field(default=None, max_length=500)
    website: str | None = Field(default=None, max_length=500)

    # Client optional profile fields (Task 4) — meaningful only for
    # client accounts; a future edit-profile endpoint is expected to
    # ignore/reject these for photographer accounts. All optional/nullable.
    profile_photo_url: str | None = Field(default=None, max_length=500)
    gender: str | None = Field(default=None, max_length=20)
    date_of_birth: date | None = None
    preferred_photo_types: list[str] | None = None
    preferred_city: str | None = Field(default=None, max_length=100)
    budget_min: float | None = None
    budget_max: float | None = None

    # Privacy & Security screen — "Download Permissions" toggle. Shared
    # by both roles (unlike the studio/client-only fields above).
    allow_downloads: bool | None = None
    private_profile: bool | None = None

    # Notification Settings screen — "Push Notifications" and "Email Notifications" toggles.
    # Shared by both roles. Persisted server-side for cross-device consistency.
    push_notifications_enabled: bool | None = None
    email_notifications_enabled: bool | None = None

    # App Settings screen — "App Language" picker. Shared by both roles.
    app_language: str | None = Field(default=None, max_length=30)


class UserUpdatePermissions(BaseModel):
    """Payload for PUT /auth/permissions — items 15-17 (Camera / Photo
    Library / Push Notification prompts). All fields optional so each
    screen can send just the one flag it owns; unset fields are left
    untouched. The client requests the real OS permission first (via
    `permission_handler`) and sends the actual result here — this
    endpoint has no way to independently verify OS permission state
    itself, it just records the flag it's given.
    """

    camera_permission_granted: bool | None = None
    photo_library_permission_granted: bool | None = None
    push_notifications_enabled: bool | None = None


class VerifyEmailRequest(BaseModel):
    """Payload for POST /auth/verify-email — the token from the (dummy)
    verification email/link."""

    token: str


class ForgotPasswordRequest(BaseModel):
    """Payload for POST /auth/forgot-password."""

    email: EmailStr


class ActivatePlanRequest(BaseModel):
    plan: str


class ResetPasswordRequest(BaseModel):
    """Payload for POST /auth/reset-password — the token from the
    (dummy) reset-password email/link plus the new password."""

    token: str
    new_password: str = Field(min_length=8, max_length=128)

    @field_validator("new_password")
    @classmethod
    def _password_has_digit(cls, value: str) -> str:
        if not any(ch.isdigit() for ch in value):
            raise ValueError("Password must include at least one number")
        return value


class DeleteAccountRequest(BaseModel):
    """Payload for DELETE /users/me. `password` is required for local
    (email/password) accounts and is verified against the stored hash
    before anything is deleted. It's optional here — rather than
    required — only because Google/Apple sign-in accounts have no
    password at all (see `User.hashed_password`); the route itself
    still enforces it for local accounts."""

    password: str | None = None


class MessageResponse(BaseModel):
    message: str


class UserRead(BaseModel):
    model_config = ConfigDict(from_attributes=True, use_enum_values=True)

    id: uuid.UUID
    full_name: str
    email: EmailStr
    role: UserRole
    auth_provider: AuthProvider
    studio_name: str | None
    studio_address: str | None
    business_type: str | None
    avatar_url: str | None
    cover_image_url: str | None = None
    country: str | None
    state: str | None
    city: str | None
    address: str | None
    bio: str | None
    specializations: list[str] | None = None
    is_email_verified: bool
    camera_permission_granted: bool
    photo_library_permission_granted: bool
    push_notifications_enabled: bool
    email_notifications_enabled: bool = True
    fcm_token: str | None = None
    allow_downloads: bool
    private_profile: bool
    app_language: str
    created_at: datetime

    # Studio profile fields (Task 3) — nullable, populated only for
    # photographer ("Studio") accounts.
    year_established: int | None = None
    team_size: int | None = None
    service_areas: list[str] | None = None
    studio_type: str | None = None
    experience_years: int | None = None
    languages: list[str] | None = None
    equipment_highlights: str | None = None
    pricing_min: float | None = None
    pricing_max: float | None = None
    package_details: str | None = None
    availability_days: list[str] | None = None
    instagram_url: str | None = None
    facebook_url: str | None = None
    youtube_url: str | None = None
    pinterest_url: str | None = None
    website: str | None = None

    # Client optional profile fields (Task 4) — nullable, populated only
    # for client accounts.
    profile_photo_url: str | None = None
    gender: str | None = None
    date_of_birth: date | None = None
    preferred_photo_types: list[str] | None = None
    preferred_city: str | None = None
    budget_min: float | None = None
    budget_max: float | None = None

    # Subscription fields — from the DB columns added via SQL migration.
    # Exposed as-is so the Flutter app can derive plan/status locally.
    current_plan: str | None = None       # "trial" | "pro" | "premium" | None
    plan_status: str | None = None        # "active" | "inactive" | "expired" | None
    plan_expiry: datetime | None = None   # UTC expiry timestamp
    trial_used: bool = False              # whether free trial has been used
    plan_started_at: datetime | None = None

    # ── Computed convenience fields for the Flutter AppUser model ────────────
    # Flutter reads `subscription_status` and `current_plan` directly.
    # We map plan_status to subscription_status to match what Flutter expects.
    @computed_field
    @property
    def subscription_status(self) -> str:
        """Maps DB plan_status to the Flutter app's expected values.
        Returns 'trial' when current_plan is 'trial' and still active,
        so the Flutter app can correctly identify and style trial plans.
        """
        if self.plan_status == "active":
            expiry = self.plan_expiry
            if expiry is not None:
                if expiry.tzinfo is None:
                    expiry = expiry.replace(tzinfo=timezone.utc)
                if datetime.now(timezone.utc) > expiry:
                    return "expired"
            if self.current_plan == "trial":
                return "trial"
            return "active"
        if self.plan_status == "expired":
            return "expired"
        return "none"

    @field_validator(
        "specializations",
        "service_areas",
        "languages",
        "availability_days",
        "preferred_photo_types",
        mode="before",
    )
    @classmethod
    def _split_csv_fields(cls, value):
        # DB stores these as a comma-separated string; expose them to
        # clients as a list to match the Flutter chip-selection UI.
        if isinstance(value, str):
            return [v.strip() for v in value.split(",") if v.strip()]
        return value


class Token(BaseModel):
    access_token: str
    refresh_token: str | None = None
    access: str | None = None
    refresh: str | None = None
    token_type: str = "bearer"
    user: UserRead


class TokenRefreshRequest(BaseModel):
    refresh_token: str | None = None
    refresh: str | None = None

    @model_validator(mode="after")
    def validate_refresh_token(self) -> "TokenRefreshRequest":
        if not self.refresh_token and not self.refresh:
            raise ValueError("Refresh token is required")
        return self

    @property
    def token_str(self) -> str:
        return self.refresh_token or self.refresh or ""


class TokenRefreshResponse(BaseModel):
    access_token: str
    refresh_token: str | None = None
    access: str | None = None
    refresh: str | None = None
    token_type: str = "bearer"