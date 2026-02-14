import os
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

class Settings:
    # Spotify Configuration
    # Variables will be loaded from .env, or return None if not found
    SPOTIFY_CLIENT_ID = os.getenv("CLIENT_ID")
    SPOTIFY_CLIENT_SECRET = os.getenv("CLIENT_SECRET")
    
    # Redirect URI is required by Spotify dashboard
    # Use loopback address as recommended by Spotify security guidelines
    SPOTIFY_REDIRECT_URI = "http://127.0.0.1:8000/callback"
    
    # Database Configuration
    DATABASE_URL = "sqlite:///./music_app.db"

    # Auth Configuration
    JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY", "change-me-in-production")
    JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
    JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "10080"))

settings = Settings()
