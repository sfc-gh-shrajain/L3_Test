import gspread
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from google_auth_httplib2 import AuthorizedHttp
import httplib2
from src.config import GOOGLE_CREDENTIALS_FILE

SCOPES = [
    "https://spreadsheets.google.com/feeds",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/presentations",
]


def get_credentials():
    return Credentials.from_service_account_file(GOOGLE_CREDENTIALS_FILE, scopes=SCOPES)


def get_gspread_client():
    creds = get_credentials()
    return gspread.authorize(creds)


def get_sheets_service():
    creds = get_credentials()
    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def get_slides_service():
    creds = get_credentials()
    return build("slides", "v1", credentials=creds, cache_discovery=False)


def get_drive_service():
    creds = get_credentials()
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def copy_file(file_id, title, folder_id=None):
    creds = get_credentials()
    http = AuthorizedHttp(creds, http=httplib2.Http())
    drive = build("drive", "v3", http=http, cache_discovery=False)
    body = {"name": title}
    if folder_id:
        body["parents"] = [folder_id]
    copied = drive.files().copy(
        fileId=file_id, body=body, supportsAllDrives=True
    ).execute()
    return copied["id"]


def share_file_with_user(file_id, user_name, send_notification=True):
    email = user_name.lower().replace(" ", ".") + "@snowflake.com"
    drive = get_drive_service()
    try:
        drive.permissions().create(
            fileId=file_id,
            body={"type": "user", "role": "writer", "emailAddress": email},
            supportsAllDrives=True,
            sendNotificationEmail=send_notification,
        ).execute()
        return email
    except Exception:
        return None
