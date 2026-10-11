from datetime import datetime, timedelta, timezone
from typing import Optional
import hashlib
import hmac

from jose import JWTError, jwt
from passlib.context import CryptContext

from config import settings


pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return pwd_context.verify(password, password_hash)


def create_access_token(user_id: int, username: str) -> str:
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=settings.JWT_EXPIRE_MINUTES)
    payload = {
        "sub": str(user_id),
        "username": username,
        "exp": expires_at,
    }
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)


def decode_access_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(
            token,
            settings.JWT_SECRET_KEY,
            algorithms=[settings.JWT_ALGORITHM],
        )
        return payload if payload.get("purpose") != "media" else None
    except JWTError:
        return None


def _media_key():
    return hmac.new(settings.JWT_SECRET_KEY.encode(), b"mymusic/media/v1", hashlib.sha256).hexdigest()


def create_media_token(user_id: int, path: str):
    expires = int((datetime.now(timezone.utc) + timedelta(seconds=getattr(settings, "MEDIA_TOKEN_SECONDS", 7200))).timestamp())
    payload = {"sub": str(user_id), "path": path, "purpose": "media", "aud": "mymusic-media", "exp": expires}
    return jwt.encode(payload, _media_key(), algorithm=settings.JWT_ALGORITHM), expires


def decode_media_token(token: str, path: str):
    try:
        payload = jwt.decode(token, _media_key(), algorithms=[settings.JWT_ALGORITHM], audience="mymusic-media")
        if payload.get("purpose") == "media" and payload.get("path") == path:
            return payload
    except JWTError:
        pass
    return None
