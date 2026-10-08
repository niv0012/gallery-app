from datetime import datetime, timezone, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status, File, UploadFile
import uuid
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.security import verify_password
from app.core.firebase_service import send_push_notification
from app.core.email import send_subscription_activated_email
from app.db.session import get_db
from app.models.user import AuthProvider, User, UserRole
from app.schemas.user import ActivatePlanRequest, DeleteAccountRequest, MessageResponse, UserRead, UserUpdate
from app.schemas.studio import AvatarUploadResponse
from app.core.storage import save_upload, build_media_url

_ALLOWED_IMAGE_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"}


def _validate_image_upload(upload: UploadFile) -> None:
    if upload.content_type not in _ALLOWED_IMAGE_CONTENT_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Please upload a JPEG, PNG, WEBP, or HEIC image.",
        )


router = APIRouter(prefix="/users", tags=["users"])

# Fields whose DB column stores a comma-separated string but is exposed
# to/from the client as a list (same convention `UserRead` already uses
# for `specializations` via `_split_csv_fields`).
_LIST_FIELDS = {
    "service_areas",
    "specializations",
    "languages",
    "availability_days",
    "preferred_photo_types",
}

# Studio profile fields (Task 8-9) — meaningful only for photographer
# accounts; ignored (not rejected) if a client payload happens to
# include them, since the Flutter screen never sends them for clients.
_PHOTOGRAPHER_ONLY_FIELDS = {
    "studio_address",
    "year_established",
    "team_size",
    "service_areas",
    "specializations",
    "studio_type",
    "experience_years",
    "languages",
    "equipment_highlights",
    "pricing_min",
    "pricing_max",
    "package_details",
    "availability_days",
    "instagram_url",
    "facebook_url",
    "youtube_url",
    "pinterest_url",
    "website",
}

# Client optional profile fields (Task 8) — meaningful only for client
# accounts; ignored (not rejected) if a photographer payload happens to
# include them.
_CLIENT_ONLY_FIELDS = {
    "gender",
    "date_of_birth",
    "preferred_photo_types",
    "preferred_city",
    "budget_min",
    "budget_max",
}

# Fields where the Flutter screen currently sends "" (not null) to mean
# "cleared", since `_handleSave()` uses `.text.trim()` for these instead
# of `_emptyToNull()`. Normalized to None here so a cleared field
# actually clears rather than storing "". Originally just the
# social-link URLs.
_EMPTY_TO_NULL_FIELDS = {"instagram_url", "facebook_url", "youtube_url", "pinterest_url", "website"}


@router.patch("/me", response_model=UserRead)
def update_profile(
    payload: UserUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Backs the Edit Profile screen (Task 7). Only fields actually
    present in the request body are touched
    (`UserUpdate.model_dump(exclude_unset=True)`) — an omitted field is
    left alone, matching what `UserRepository.updateProfile()` on the
    Flutter side already assumes. Role-mismatched fields (e.g.
    `studio_type` sent while the account is a client) are silently
    ignored rather than rejected, since the Flutter screen never sends
    them for the "wrong" role in the first place.
    """
    updates = payload.model_dump(exclude_unset=True)

    is_photographer = current_user.role == UserRole.photographer
    for field, value in updates.items():
        if is_photographer and field in _CLIENT_ONLY_FIELDS:
            continue
        if not is_photographer and field in _PHOTOGRAPHER_ONLY_FIELDS:
            continue

        if field in _LIST_FIELDS:
            value = ",".join(value) if value else None
        elif field in _EMPTY_TO_NULL_FIELDS and value == "":
            value = None

        setattr(current_user, field, value)

    db.commit()
    db.refresh(current_user)
    return current_user


@router.post("/me/plan", response_model=UserRead)
def activate_plan(
    payload: ActivatePlanRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> User:
    """Activates a subscription plan for the user."""
    if payload.plan not in ("trial", "pro", "premium"):
        raise HTTPException(status_code=400, detail="Invalid plan")

    if payload.plan == "trial":
        if current_user.trial_used:
            raise HTTPException(status_code=400, detail="Trial already used")
        current_user.trial_used = True
        duration = timedelta(days=5)
    elif payload.plan == "pro":
        duration = timedelta(days=182)
    elif payload.plan == "premium":
        duration = timedelta(days=365)
    else:
        duration = timedelta(days=0)

    now = datetime.now(timezone.utc)
    current_user.current_plan = payload.plan
    current_user.plan_status = "active"
    current_user.plan_started_at = now
    # Reset reminder tracking so the new plan cycle sends all thresholds fresh.
    current_user.last_reminder_days = None

    # If adding time to an active plan, append to expiry instead of replacing
    if current_user.plan_expiry:
        expiry = current_user.plan_expiry
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        if expiry > now:
            current_user.plan_expiry = expiry + duration
        else:
            current_user.plan_expiry = now + duration
    else:
        current_user.plan_expiry = now + duration

    db.commit()
    db.refresh(current_user)

    # ── Post-activation notifications (best-effort, never fail the request) ──
    _plan_label = {
        "trial": "5-Day Free Trial",
        "pro": "Pro (6 Months)",
        "premium": "Premium (1 Year)",
    }.get(payload.plan, payload.plan.title())
    _expiry_str = (
        current_user.plan_expiry.strftime("%d %b %Y, %I:%M %p UTC")
        if current_user.plan_expiry
        else "N/A"
    )

    # Push notification — only if the device has registered an FCM token
    if current_user.fcm_token:
        send_push_notification(
            token=current_user.fcm_token,
            title="🎉 Subscription Activated!",
            body=f"Your {_plan_label} plan is now active. Valid until {_expiry_str}.",
            data={
                "type": "subscription_activated",
                "plan": payload.plan,
                "expiry": _expiry_str,
            },
        )

    # Email confirmation — always attempted (send_email is a no-op when SMTP
    # is not configured, so this is safe in local dev too)
    send_subscription_activated_email(
        to_email=current_user.email,
        full_name=current_user.full_name,
        plan=payload.plan,
        expiry=_expiry_str,
    )

    return current_user


@router.delete("/me", response_model=MessageResponse)
def delete_account(
    payload: DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> MessageResponse:
    """Backs the Delete Account screen. Soft-deletes the authenticated
    user: flips `is_deleted`/`deleted_at`, anonymizes the email (freeing
    it up for a future new account), clears the password and any
    outstanding verification/reset tokens, and unlinks any Google/Apple
    identity. The row itself is kept (not hard-deleted) so it doesn't
    orphan anything elsewhere that references this user.

    Requires the account password for local (email/password) accounts,
    same as any other destructive "are you sure" confirmation — there's
    no separate re-auth step in this app to fall back on. Google/Apple
    accounts have no password to check, so the request is trusted on
    the strength of the (already-verified) access token alone.

    Every subsequent request made with this user's current access
    token is rejected the moment `get_current_user` sees `is_deleted`
    True, which is what "revokes" the token — there is no separate
    token/session store to invalidate.
    """
    if current_user.auth_provider == AuthProvider.local:
        if not payload.password:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Password is required to delete your account",
            )
        if not current_user.hashed_password or not verify_password(payload.password, current_user.hashed_password):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Incorrect password")

    current_user.is_deleted = True
    current_user.deleted_at = datetime.now(timezone.utc)
    current_user.email = f"deleted-{current_user.id}@deleted.picgallery.local"
    current_user.hashed_password = None
    current_user.provider_user_id = None
    current_user.email_verification_token = None
    current_user.reset_password_token = None
    db.commit()

    return MessageResponse(message="Your account has been deleted.")

@router.post("/me/avatar", response_model=AvatarUploadResponse)
def upload_user_avatar(
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> AvatarUploadResponse:
    """Uploads/replaces the user's profile picture/avatar."""
    _validate_image_upload(file)

    relative_path, _size = save_upload(owner_id=current_user.id, media_id=uuid.uuid4(), upload=file)
    current_user.avatar_url = build_media_url(relative_path)
    db.commit()

    return AvatarUploadResponse(avatar_url=current_user.avatar_url, cover_image_url=current_user.cover_image_url)