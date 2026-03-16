"""
Google Slides Manager Module (OAuth Version)
Handles all Google Slides API interactions using OAuth 2.0 authentication
Optimized for organizational environments with sharing restrictions
"""

import io
import time
from typing import Dict, Any
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload
from googleapiclient.errors import HttpError
import pandas as pd


class GoogleSlidesManagerOAuth:
    """Manager class for Google Slides API operations with OAuth"""
    
    def __init__(self, credentials, enable_charts=True):
        """
        Initialize Google Slides Manager with OAuth credentials
        
        Args:
            credentials: OAuth 2.0 credentials object
            enable_charts: Whether to attempt chart image embedding (may fail in restricted orgs)
        """
        self.credentials = credentials
        self.slides_service = build('slides', 'v1', credentials=self.credentials, cache_discovery=False)
        self.drive_service = build('drive', 'v3', credentials=self.credentials, cache_discovery=False)
        self.enable_charts = enable_charts
    
    def get_or_create_folder(self, folder_name: str) -> str:
        """
        Get existing folder or create a new one with retry logic
        
        Args:
            folder_name: Name of the folder
            
        Returns:
            Folder ID or None if it fails (will create files in root)
        """
        import time
        from googleapiclient.errors import HttpError
        
        max_retries = 3
        retry_delay = 2  # seconds
        
        for attempt in range(max_retries):
            try:
                # Search for existing folder
                query = f"name='{folder_name}' and mimeType='application/vnd.google-apps.folder' and trashed=false"
                results = self.drive_service.files().list(
                    q=query,
                    spaces='drive',
                    fields='files(id, name)'
                ).execute()
                
                folders = results.get('files', [])
                
                if folders:
                    # Folder exists, return its ID
                    return folders[0]['id']
                else:
                    # Create new folder
                    file_metadata = {
                        'name': folder_name,
                        'mimeType': 'application/vnd.google-apps.folder'
                    }
                    folder = self.drive_service.files().create(
                        body=file_metadata,
                        fields='id'
                    ).execute()
                    return folder.get('id')
            
            except HttpError as e:
                if e.resp.status in [500, 503] and attempt < max_retries - 1:
                    # Retry on server errors
                    print(f"Retry {attempt + 1}/{max_retries} after {retry_delay}s due to: {str(e)}")
                    time.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                else:
                    # Give up and return None (files will be created in root)
                    print(f"Failed to get/create folder after {max_retries} attempts: {str(e)}")
                    return None
            except Exception as e:
                print(f"Unexpected error in folder operation: {str(e)}")
                return None
        
        return None

    
    def get_or_create_user_folder(self, user_email: str, parent_folder_id: str = None) -> str:
        """
        Get or create a folder named after the user's email.
        
        Args:
            user_email: User's email address (will be used as folder name)
            parent_folder_id: Optional parent folder ID (e.g., shared drive folder)
            
        Returns:
            Folder ID or None if it fails
        """
        import time
        from googleapiclient.errors import HttpError
        
        # Sanitize email for folder name (replace @ and . with safe characters)
        folder_name = user_email.replace('@', '_at_').replace('.', '_')
        
        max_retries = 3
        retry_delay = 2
        
        for attempt in range(max_retries):
            try:
                # Search for existing folder
                if parent_folder_id:
                    query = f"name='{folder_name}' and mimeType='application/vnd.google-apps.folder' and '{parent_folder_id}' in parents and trashed=false"
                else:
                    query = f"name='{folder_name}' and mimeType='application/vnd.google-apps.folder' and trashed=false"
                
                results = self.drive_service.files().list(
                    q=query,
                    spaces='drive',
                    fields='files(id, name)',
                    supportsAllDrives=True,
                    includeItemsFromAllDrives=True
                ).execute()
                
                folders = results.get('files', [])
                
                if folders:
                    # Folder exists, return its ID
                    return folders[0]['id']
                else:
                    # Create new folder
                    file_metadata = {
                        'name': folder_name,
                        'mimeType': 'application/vnd.google-apps.folder'
                    }
                    if parent_folder_id:
                        file_metadata['parents'] = [parent_folder_id]
                    
                    folder = self.drive_service.files().create(
                        body=file_metadata,
                        fields='id',
                        supportsAllDrives=True
                    ).execute()
                    return folder.get('id')
            
            except HttpError as e:
                if e.resp.status in [500, 503] and attempt < max_retries - 1:
                    print(f"Retry {attempt + 1}/{max_retries} after {retry_delay}s due to: {str(e)}")
                    time.sleep(retry_delay)
                    retry_delay *= 2
                else:
                    print(f"Failed to get/create user folder: {str(e)}")
                    return None
            except Exception as e:
                print(f"Unexpected error in user folder operation: {str(e)}")
                return None
        
        return None
    
    def share_with_user(self, file_id: str, user_email: str, role: str = 'writer') -> bool:
        """
        Share a file or folder with a user by email.
        
        Args:
            file_id: ID of the file or folder to share
            user_email: Email address of the user to share with
            role: Permission role ('reader', 'writer', 'commenter')
            
        Returns:
            True if sharing was successful, False otherwise
        """
        from googleapiclient.errors import HttpError
        
        try:
            permission = {
                'type': 'user',
                'role': role,
                'emailAddress': user_email
            }
            
            self.drive_service.permissions().create(
                fileId=file_id,
                body=permission,
                fields='id',
                sendNotificationEmail=False,  # Don't spam the user
                supportsAllDrives=True
            ).execute()
            
            return True
        except HttpError as e:
            # 400 error might mean user already has access
            if e.resp.status == 400:
                print(f"User {user_email} may already have access: {str(e)}")
                return True
            print(f"Failed to share with {user_email}: {str(e)}")
            return False
        except Exception as e:
            print(f"Unexpected error sharing with user: {str(e)}")
            return False
 
        
    def move_file_to_folder(self, file_id: str, folder_id: str):
        """
        Move a file to a specific folder
        
        Args:
            file_id: ID of the file to move
            folder_id: ID of the destination folder
        """
        # Get current parents (supports Shared Drives)
        file = self.drive_service.files().get(
            fileId=file_id,
            fields='parents',
            supportsAllDrives=True
        ).execute()
        
        previous_parents = ",".join(file.get('parents', []))
        
        # Move to new folder (supports Shared Drives)
        self.drive_service.files().update(
            fileId=file_id,
            addParents=folder_id,
            removeParents=previous_parents,
            fields='id, parents',
            supportsAllDrives=True
        ).execute()
    
    def find_file_by_name(self, file_name: str, folder_id: str = None) -> str:
        """
        Find a file by name in a specific folder
        
        Args:
            file_name: Name of the file to find
            folder_id: ID of the folder to search in (optional)
            
        Returns:
            File ID if found, None otherwise
        """
        query = f"name='{file_name}' and trashed=false"
        if folder_id:
            query += f" and '{folder_id}' in parents"
        
        results = self.drive_service.files().list(
            q=query,
            spaces='drive',
            fields='files(id, name)',
            pageSize=1,
            supportsAllDrives=True,
            includeItemsFromAllDrives=True
        ).execute()
        
        files = results.get('files', [])
        return files[0]['id'] if files else None
    
    def delete_file(self, file_id: str):
        """
        Delete a file from Drive
        
        Args:
            file_id: ID of the file to delete
        """
        try:
            self.drive_service.files().delete(fileId=file_id, supportsAllDrives=True).execute()
        except Exception as e:
            print(f"Warning: Could not delete file {file_id}: {e}")
    
    def create_presentation(self, title: str, folder_id: str = None) -> Dict[str, Any]:
        """
        Create a new Google Slides presentation in user's Drive
        
        Args:
            title: Title of the presentation
            folder_id: Optional folder ID to place the presentation in
            
        Returns:
            Dictionary containing presentation ID and URL
        """
        presentation = {
            'title': title
        }
        
        presentation = self.slides_service.presentations().create(
            body=presentation
        ).execute()
        
        presentation_id = presentation.get('presentationId')
        
        # Move to folder if specified (supports Shared Drives)
        if folder_id:
            # Get current parents
            file = self.drive_service.files().get(
                fileId=presentation_id,
                fields='parents',
                supportsAllDrives=True
            ).execute()
            previous_parents = ",".join(file.get('parents', []))
            
            # Move to new folder
            self.drive_service.files().update(
                fileId=presentation_id,
                addParents=folder_id,
                removeParents=previous_parents,
                fields='id, parents',
                supportsAllDrives=True
            ).execute()
        
        # Delete the auto-created blank first slide
        slides = presentation.get('slides', [])
        if slides:
            first_slide_id = slides[0]['objectId']
            delete_request = {
                'requests': [
                    {
                        'deleteObject': {
                            'objectId': first_slide_id
                        }
                    }
                ]
            }
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body=delete_request
            ).execute()
        
        return {
            'presentationId': presentation_id,
            'presentation_id': presentation_id,
            'url': f"https://docs.google.com/presentation/d/{presentation_id}/edit"
        }
    
    def add_footer_to_slide(self, presentation_id: str, slide_id: str, 
                           page_number: int, footer_image_path: str = "footer.png") -> None:
        """
        Add footer to a slide with logo, copyright text, and page number
        
        Args:
            presentation_id: ID of the presentation
            slide_id: ID of the slide to add footer to
            page_number: Page number to display
            footer_image_path: Path to footer logo image
        """
        from datetime import datetime
        
        # Get current year dynamically
        current_year = datetime.now().year
        copyright_text = f"© {current_year} Snowflake Inc. All Rights Reserved"
        
        # 1 inch = 914400 EMU
        # Footer positioning (bottom of slide, which is typically 7.5 inches)
        footer_y = 7.0  # inches from top
        footer_y_emu = int(footer_y * 914400)
        
        # Logo dimensions and position (left bottom)
        logo_width = 0.3  # inches
        logo_height = 0.3  # inches
        logo_x = 0.3  # inches from left
        
        requests = []
        
        # Add footer logo image
        import os
        logo_url = None
        if os.path.exists(footer_image_path):
            try:
                from googleapiclient.http import MediaFileUpload
                file_metadata = {'name': os.path.basename(footer_image_path)}
                media = MediaFileUpload(footer_image_path, mimetype='image/png')
                uploaded_file = self.drive_service.files().create(
                    body=file_metadata,
                    media_body=media,
                    fields='id'
                ).execute()
                
                # Make it publicly accessible
                self.drive_service.permissions().create(
                    fileId=uploaded_file['id'],
                    body={'type': 'anyone', 'role': 'reader'}
                ).execute()
                
                # Get the public URL
                logo_url = f"https://drive.google.com/uc?export=view&id={uploaded_file['id']}"
                
                requests.append({
                    'createImage': {
                        'url': logo_url,
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': int(logo_height * 914400), 'unit': 'EMU'},
                                'width': {'magnitude': int(logo_width * 914400), 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': int(logo_x * 914400),
                                'translateY': footer_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                })
            except Exception as e:
                print(f"Warning: Could not add footer logo: {e}")
        
        # Add copyright text (next to logo)
        copyright_x = logo_x + logo_width + 0.1  # inches (logo + small gap)
        requests.extend([
            {
                'createShape': {
                    'objectId': f'footer_copyright_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 228600, 'unit': 'EMU'},  # 0.25 inches
                            'width': {'magnitude': 3657600, 'unit': 'EMU'}   # 4 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(copyright_x * 914400),
                            'translateY': footer_y_emu,
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'footer_copyright_{slide_id}',
                    'text': copyright_text,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'footer_copyright_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 8, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                # White text for cover slide (page 1), grey for others
                                'rgbColor': {'red': 1.0, 'green': 1.0, 'blue': 1.0} if page_number == 1 
                                           else {'red': 0.4, 'green': 0.4, 'blue': 0.4}
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily'
                }
            }
        ])
        
        # Add page number (right bottom)
        page_number_x = 9.2  # inches (right side)
        requests.extend([
            {
                'createShape': {
                    'objectId': f'footer_page_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 228600, 'unit': 'EMU'},  # 0.25 inches
                            'width': {'magnitude': 457200, 'unit': 'EMU'}    # 0.5 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(page_number_x * 914400),
                            'translateY': footer_y_emu,
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'footer_page_{slide_id}',
                    'text': str(page_number),
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'footer_page_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 10, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                # White text for cover slide (page 1), grey for others
                                'rgbColor': {'red': 1.0, 'green': 1.0, 'blue': 1.0} if page_number == 1 
                                           else {'red': 0.4, 'green': 0.4, 'blue': 0.4}
                            }
                        },
                        'fontFamily': 'Arial',
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'footer_page_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Execute all footer requests
        if requests:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
    
    def add_cover_slide(self, presentation_id: str, customer_name: str, 
                       sales_rep_name: str = "Connor Gibbs", 
                       se_name: str = "Jordan Hill",
                       month_year: str = "May 2025",
                       logo_path: str = "logo-white.png") -> str:
        """
        Add a custom cover slide matching the Snowflake template
        
        Args:
            presentation_id: ID of the presentation
            customer_name: Customer/Account name (e.g., "NBA")
            sales_rep_name: Sales representative name
            se_name: Sales engineer name
            month_year: Month and year (e.g., "May 2025")
            
        Returns:
            Slide ID
        """
        # Create blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    },
                    'insertionIndex': 0  # Insert at the beginning
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Option 1: Use pre-uploaded logo from Drive (RECOMMENDED)
        # Set this to your logo's Drive file ID to avoid repeated uploads
        LOGO_DRIVE_FILE_ID = "1nUxTUOYFM7NMSUUjDAV6fPmhqp39xjFY"  # Pre-uploaded logo file
        
        import os
        logo_url = None
        if LOGO_DRIVE_FILE_ID:
            # Use pre-uploaded logo from Drive - use uc?export=download format for Slides API
            logo_url = f"https://drive.google.com/uc?export=download&id={LOGO_DRIVE_FILE_ID}"
        elif os.path.exists(logo_path):
            # Option 2: Upload logo dynamically (slower, may have permission issues)
            try:
                from googleapiclient.http import MediaFileUpload
                file_metadata = {'name': 'logo-white.png'}
                media = MediaFileUpload(logo_path, mimetype='image/png')
                uploaded_file = self.drive_service.files().create(
                    body=file_metadata,
                    media_body=media,
                    fields='id,webContentLink'
                ).execute()
                
                # Try to make it publicly accessible (optional - may fail due to permissions)
                try:
                    self.drive_service.permissions().create(
                        fileId=uploaded_file['id'],
                        body={'type': 'anyone', 'role': 'reader'}
                    ).execute()
                except Exception as perm_error:
                    # Permission setting failed, but file is still uploaded and accessible to authenticated user
                    pass
                
                # Use webContentLink if available, otherwise use the drive file ID directly
                if 'webContentLink' in uploaded_file:
                    logo_url = uploaded_file['webContentLink']
                else:
                    # Use the Drive thumbnail/preview URL
                    logo_url = f"https://drive.google.com/thumbnail?id={uploaded_file['id']}&sz=w1000"
            except Exception as e:
                print(f"Warning: Could not upload logo: {str(e)}")
                logo_url = None  # Ensure logo_url is None if upload fails
        
        # Set blue background and add all elements
        # 1 inch = 914400 EMU
        content_requests = [
            # Set background color to blue #29B5E8
            {
                'updatePageProperties': {
                    'objectId': slide_id,
                    'pageProperties': {
                        'pageBackgroundFill': {
                            'solidFill': {
                                'color': {
                                    'rgbColor': {
                                        'red': 0.161,
                                        'green': 0.710,
                                        'blue': 0.910
                                    }
                                }
                            }
                        }
                    },
                    'fields': 'pageBackgroundFill.solidFill.color'
                }
            }
        ]
        
        # Add logo if URL is available - X=0.45, Y=0.25, Width=2.37, Height=0.56
        # TEMPORARILY DISABLED - Logo causing HTTP 500 error
        # TODO: Fix logo insertion issue
        if False and logo_url:
            content_requests.append({
                'createImage': {
                    'url': logo_url,
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 512064, 'unit': 'EMU'},  # 0.56 inches
                            'width': {'magnitude': 2167128, 'unit': 'EMU'}   # 2.37 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 228600,   # 0.25 inches
                            'unit': 'EMU'
                        }
                    }
                }
            })
        
        # Add text elements
        content_requests.extend([
            # Customer name (e.g., "NBA") - X=0.45, Y=1.82, Font Size=44
            {
                'createShape': {
                    'objectId': f'customer_name_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 914400, 'unit': 'EMU'},  # 1 inch
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}    # 9 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 1664208,  # 1.82 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'customer_name_{slide_id}',
                    'text': customer_name.upper(),
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'customer_name_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 44, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 1.0, 'green': 1.0, 'blue': 1.0}
                            }
                        },
                        'bold': False,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # "SNOWFLAKE" - X=0.45, Y=2.71, Font Size=50
            {
                'createShape': {
                    'objectId': f'snowflake_text_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 914400, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 2478024,  # 2.71 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'snowflake_text_{slide_id}',
                    'text': 'SNOWFLAKE',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'snowflake_text_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 50, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'bold': True,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # "New Contract Proposal" - X=0.45, Y=3.66, Font Size=18
            {
                'createShape': {
                    'objectId': f'subtitle_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 457200, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 3346704,  # 3.66 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'subtitle_{slide_id}',
                    'text': 'New Contract Proposal',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'subtitle_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 18, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 1.0, 'green': 1.0, 'blue': 1.0}
                            }
                        },
                        'bold': True,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # Sales rep name - X=0.45, Y=4.16, Font Size=16
            {
                'createShape': {
                    'objectId': f'sales_rep_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 3803904,  # 4.16 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'sales_rep_{slide_id}',
                    'text': sales_rep_name,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'sales_rep_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 16, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'bold': True,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # SE name - X=0.45, Y=4.56, Font Size=16
            {
                'createShape': {
                    'objectId': f'se_name_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 4169664,  # 4.56 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'se_name_{slide_id}',
                    'text': se_name,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'se_name_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 16, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'bold': True,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # Date - X=0.45, Y=4.96, Font Size=16
            {
                'createShape': {
                    'objectId': f'date_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 4535424,  # 4.96 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'date_{slide_id}',
                    'text': month_year,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'date_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 16, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'bold': True,
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,bold,fontFamily'
                }
            },
            # Copyright footer
            {
                'createShape': {
                    'objectId': f'copyright_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 228600, 'unit': 'EMU'},
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 657360,
                            'translateY': 6400800,  # 7.0 inches (bottom)
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'copyright_{slide_id}',
                    'text': '© 2025 Snowflake Inc. All Rights Reserved',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'copyright_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 10, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 1.0, 'green': 1.0, 'blue': 1.0}
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily'
                }
            }
        ])
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': content_requests}
        ).execute()
        
        # Add footer to cover slide
        # self.add_footer_to_slide(presentation_id, slide_id, page_number=1)
        
        return slide_id
    
    def add_title_slide(self, presentation_id: str, title: str, subtitle: str = ""):
        """
        Add a title slide to the presentation
        
        Args:
            presentation_id: ID of the presentation
            title: Main title text
            subtitle: Subtitle text (optional)
        """
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'TITLE'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Update title and subtitle
        requests = []
        
        # Get the slide to find text box IDs
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        for slide in presentation.get('slides', []):
            if slide['objectId'] == slide_id:
                for element in slide.get('pageElements', []):
                    if 'shape' in element:
                        shape = element['shape']
                        if shape.get('shapeType') == 'TEXT_BOX':
                            placeholder = shape.get('placeholder', {})
                            if placeholder.get('type') == 'CENTERED_TITLE' or placeholder.get('type') == 'TITLE':
                                requests.append({
                                    'insertText': {
                                        'objectId': element['objectId'],
                                        'text': title,
                                        'insertionIndex': 0
                                    }
                                })
                            elif placeholder.get('type') == 'SUBTITLE' and subtitle:
                                requests.append({
                                    'insertText': {
                                        'objectId': element['objectId'],
                                        'text': subtitle,
                                        'insertionIndex': 0
                                    }
                                })
        
        if requests:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
        
        return slide_id
    
    def add_dual_chart_slide(self, presentation_id: str, title: str,
                            spreadsheet_id: str, chart_id_1: int, chart_id_2: int,
                            chart_1_title: str, chart_2_title: str) -> str:
        """
        Add a slide with two charts positioned vertically
        
        Args:
            presentation_id: ID of the presentation
            title: Slide title
            spreadsheet_id: ID of the source spreadsheet
            chart_id_1: ID of the first chart (top)
            chart_id_2: ID of the second chart (bottom)
            chart_1_title: Title for first chart
            chart_2_title: Title for second chart
            
        Returns:
            Slide ID
        """
        # Create a blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Add main title
        requests = [
            {
                'createShape': {
                    'objectId': f'title_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 40, 'unit': 'PT'},
                            'width': {'magnitude': 650, 'unit': 'PT'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 35,
                            'translateY': 10,
                            'unit': 'PT'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'title_{slide_id}',
                    'text': title,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'title_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 28, 'unit': 'PT'},
                        'bold': True
                    },
                    'fields': 'fontSize,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'title_{slide_id}',
                    'style': {'alignment': 'CENTER'},
                    'fields': 'alignment'
                }
            }
        ]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        # Add first chart - positioned at top
        # Using EMU (English Metric Units): 1 inch = 914400 EMU
        # Width: 8 in = 7,315,200 EMU, Height: 2 in = 1,828,800 EMU
        # X: 0.45 in = 411,480 EMU, Y: 0.8 in = 731,520 EMU, Y2: 2.99 in = 2,734,656 EMU
        chart_requests = [
            {
                'createSheetsChart': {
                    'objectId': f'chart1_{slide_id}',
                    'spreadsheetId': spreadsheet_id,
                    'chartId': chart_id_1,
                    'linkingMode': 'LINKED',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 1828800, 'unit': 'EMU'},  # 2 inches
                            'width': {'magnitude': 7315200, 'unit': 'EMU'}    # 8 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,  # 0.45 inches
                            'translateY': 731520,  # 0.8 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'createSheetsChart': {
                    'objectId': f'chart2_{slide_id}',
                    'spreadsheetId': spreadsheet_id,
                    'chartId': chart_id_2,
                    'linkingMode': 'LINKED',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 1828800, 'unit': 'EMU'},  # 2 inches
                            'width': {'magnitude': 7315200, 'unit': 'EMU'}    # 8 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 411480,   # 0.45 inches
                            'translateY': 2734656, # 2.99 inches
                            'unit': 'EMU'
                        }
                    }
                }
            }
        ]
        
        # Execute the chart creation requests
        # Note: Size is controlled in the initial createSheetsChart request
        # Google Sheets charts may have internal sizing constraints
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': chart_requests}
        ).execute()
        
        return slide_id
    
    def add_sheets_chart_slide(self, presentation_id: str, title: str,
                               spreadsheet_id: str, chart_id: int, 
                               customer_name: str = "",
                               credit_chart_id: int = None,
                               storage_chart_id: int = None,
                               data_transfer_chart_id: int = None,
                               include_data_transfer: bool = True,
                               credit_growth_3mo: float = 0,
                               credit_growth_6mo: float = 0,
                               credit_growth_12mo: float = 0,
                               storage_growth_3mo: float = 0,
                               storage_growth_6mo: float = 0,
                               storage_growth_12mo: float = 0,
                               data_transfer_growth_3mo: float = 0,
                               data_transfer_growth_6mo: float = 0,
                               data_transfer_growth_12mo: float = 0) -> str:
        """
        Add a slide with an embedded Google Sheets chart and additional smaller charts
        
        Args:
            presentation_id: ID of the presentation
            title: Slide subtitle text (e.g., "Trailing 12 Months...")
            spreadsheet_id: ID of the source spreadsheet
            chart_id: ID of the main stacked bar chart in the spreadsheet
            customer_name: Customer name to prepend to main title
            credit_chart_id: ID of the credit consumption chart (optional)
            storage_chart_id: ID of the storage consumption chart (optional)
            data_transfer_chart_id: ID of the data transfer chart (optional)
            
        Returns:
            Slide ID
        """
        # Create a blank slide (not TITLE_AND_BODY to avoid placeholder issues)
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Build main title with customer name
        main_title_text = f"{customer_name} Monthly Consumption of Snowflake" if customer_name else "Monthly Consumption of Snowflake"
        
        # Add main title, subtitle, and chart with custom positioning
        # 1 inch = 72 PT
        requests = [
            # Main title: "{Customer Name} Monthly Consumption of Snowflake" - Size 18, Position x=0.5", y=0.14"
            {
                'createShape': {
                    'objectId': f'main_title_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 30, 'unit': 'PT'},
                            'width': {'magnitude': 650, 'unit': 'PT'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 36,      # 0.5 inch = 36 PT
                            'translateY': 10.08,   # 0.14 inch = 10.08 PT
                            'unit': 'PT'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'main_title_{slide_id}',
                    'text': main_title_text,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'fontSize': {
                            'magnitude': 18,
                            'unit': 'PT'
                        },
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'alignment': 'START'
                    },
                    'fields': 'alignment'
                }
            },
            # Subtitle: "Trailing 12 Months..." - Size 16, Position x=0.49", y=0.44"
            {
                'createShape': {
                    'objectId': f'subtitle_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 25, 'unit': 'PT'},
                            'width': {'magnitude': 650, 'unit': 'PT'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 35.28,   # 0.49 inch = 35.28 PT
                            'translateY': 31.68,    # 0.44 inch = 31.68 PT
                            'unit': 'PT'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'subtitle_{slide_id}',
                    'text': title,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'subtitle_{slide_id}',
                    'style': {
                        'fontSize': {
                            'magnitude': 16,
                            'unit': 'PT'
                        },
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.4, 'green': 0.4, 'blue': 0.4}  # Dark Grey 2
                            }
                        },
                        'bold': False
                    },
                    'fields': 'fontSize,foregroundColor,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'subtitle_{slide_id}',
                    'style': {
                        'alignment': 'START'
                    },
                    'fields': 'alignment'
                }
            }
        ]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        # Add the main Sheets chart - Position x=0.49", y=0.88"
        # Using EMU units for precise positioning
        # 1 inch = 914400 EMU
        # X: 0.49 inch = 448,056 EMU
        # Y: 0.88 inch = 804,672 EMU
        # Width: 9 inch = 8,229,600 EMU
        # Height: 1.8 inch = 1,645,920 EMU
        chart_requests = [{
            'createSheetsChart': {
                'spreadsheetId': spreadsheet_id,
                'chartId': chart_id,
                'linkingMode': 'LINKED',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': 1645920, 'unit': 'EMU'},  # 1.8 inches
                        'width': {'magnitude': 8229600, 'unit': 'EMU'}    # 9 inches
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': 448056,   # 0.49 inch
                        'translateY': 804672,   # 0.88 inch
                        'unit': 'EMU'
                    }
                }
            }
        }]
        
        # Add small text labels and charts below
        # Text label size 7pt, Arial, #29B5E8
        # 1 inch = 914400 EMU
        
        # Calculate positions and widths based on whether data transfer is included
        
        if include_data_transfer:
            # 3 charts layout - width 2.9"
            chart_width = 2.9  # inches
            credit_x = 0.49  # inches
            storage_x = 3.41  # inches
            transfer_x = 6.39  # inches
            # Growth rate label positions (same as chart positions for 3 charts)
            credit_label_x = 0.49  # inches
            storage_label_x = 3.41  # inches
        else:
            # 2 charts layout - width 4.3"
            chart_width = 4.3  # inches
            credit_x = 0.5  # inches
            storage_x = 5.06  # inches
            transfer_x = None  # Not used
            # Growth rate label positions (different from chart positions for 2 charts)
            credit_label_x = 0.88  # inches
            storage_label_x = 5.58  # inches
        
        # Y position for charts (same for both layouts)
        chart_y = 2.83  # inches
        
        # Convert to EMU
        credit_x_emu = int(credit_x * 914400)
        storage_x_emu = int(storage_x * 914400)
        credit_label_x_emu = int(credit_label_x * 914400)
        storage_label_x_emu = int(storage_label_x * 914400)
        chart_width_emu = int(chart_width * 914400)
        chart_y_emu = int(chart_y * 914400)
        
        # Text label 1: "Monthly Credit Consumption"
        chart_requests.extend([
            {
                'createShape': {
                    'objectId': f'credit_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 182880, 'unit': 'EMU'},  # 0.2 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': credit_x_emu,
                            'translateY': 2377440,  # 2.6 inch
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'credit_label_{slide_id}',
                    'text': 'Monthly Credit Consumption',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'credit_label_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 7, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.161, 'green': 0.710, 'blue': 0.910}  # #29B5E8
                            }
                        },
                        'fontFamily': 'Arial',
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'credit_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Text label 2: "Monthly Storage Consumption" - x=3.41", y=2.9"
        chart_requests.extend([
            {
                'createShape': {
                    'objectId': f'storage_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 182880, 'unit': 'EMU'},  # 0.2 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': storage_x_emu,
                            'translateY': 2377440,  # 2.6 inch
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'storage_label_{slide_id}',
                    'text': 'Monthly Storage Consumption',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'storage_label_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 7, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.161, 'green': 0.710, 'blue': 0.910}  # #29B5E8
                            }
                        },
                        'fontFamily': 'Arial',
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'storage_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Text label 3: "Monthly Data Transfer" - only if data transfer is included
        if include_data_transfer and data_transfer_chart_id:
            transfer_x_emu = int(transfer_x * 914400)
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'transfer_label_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': 182880, 'unit': 'EMU'},  # 0.2 inches
                                'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': transfer_x_emu,
                                'translateY': 2377440,  # 2.6 inch
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'transfer_label_{slide_id}',
                        'text': 'Monthly Data Transfer',
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'transfer_label_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 7, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': {'red': 0.161, 'green': 0.710, 'blue': 0.910}  # #29B5E8
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': True
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'transfer_label_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Add credit consumption chart if provided - below its label at y=3.15"
        if credit_chart_id:
            chart_requests.append({
                'createSheetsChart': {
                    'spreadsheetId': spreadsheet_id,
                    'chartId': credit_chart_id,
                    'linkingMode': 'LINKED',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 1554336, 'unit': 'EMU'},  # 1.7 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': credit_x_emu,
                            'translateY': chart_y_emu,  # Y position
                            'unit': 'EMU'
                        }
                    }
                }
            })
        
        # Add storage consumption chart if provided - below its label at y=3.15"
        if storage_chart_id:
            chart_requests.append({
                'createSheetsChart': {
                    'spreadsheetId': spreadsheet_id,
                    'chartId': storage_chart_id,
                    'linkingMode': 'LINKED',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 1554336, 'unit': 'EMU'},  # 1.7 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': storage_x_emu,
                            'translateY': chart_y_emu,  # Y position
                            'unit': 'EMU'
                        }
                    }
                }
            })
        
        # Add data transfer chart if provided and data transfer is included
        if include_data_transfer and data_transfer_chart_id:
            chart_requests.append({
                'createSheetsChart': {
                    'spreadsheetId': spreadsheet_id,
                    'chartId': data_transfer_chart_id,
                    'linkingMode': 'LINKED',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 1554336, 'unit': 'EMU'},  # 1.7 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': transfer_x_emu,
                            'translateY': chart_y_emu,  # Y position
                            'unit': 'EMU'
                        }
                    }
                }
            })
        
        # Add growth rate text boxes below charts
        # Y position: 4.4 inches = 4,023,360 EMU
        growth_rate_y_emu = 4023360
        
        # Text box 1: "Credit Monthly Growth Rate"
        chart_requests.extend([
            {
                'createShape': {
                    'objectId': f'credit_growth_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': credit_label_x_emu,
                            'translateY': growth_rate_y_emu,
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'credit_growth_label_{slide_id}',
                    'text': 'Credit Monthly Growth Rate',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'credit_growth_label_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 10, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                            }
                        },
                        'fontFamily': 'Arial',
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'credit_growth_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Text box 2: "Storage Monthly Growth Rate"
        chart_requests.extend([
            {
                'createShape': {
                    'objectId': f'storage_growth_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                            'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': storage_label_x_emu,
                            'translateY': growth_rate_y_emu,
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'storage_growth_label_{slide_id}',
                    'text': 'Storage Monthly Growth Rate',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'storage_growth_label_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 10, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                            }
                        },
                        'fontFamily': 'Arial',
                        'bold': True
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily,bold'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'storage_growth_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Text box 3: "Egress Monthly Growth Rate" - only if data transfer is included
        if include_data_transfer:
            transfer_growth_x_emu = int(6.39 * 914400)  # 6.39 inch
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'egress_growth_label_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                                'width': {'magnitude': chart_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': transfer_growth_x_emu,
                                'translateY': growth_rate_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'egress_growth_label_{slide_id}',
                        'text': 'Egress Monthly Growth Rate',
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'egress_growth_label_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 10, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': True
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'egress_growth_label_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Add growth percentage values below the labels
        # Y position: 4.68 inches = 4,279,872 EMU
        growth_values_y_emu = 4279872
        text_box_height_emu = 182880  # 0.2 inches
        text_box_width_emu = 822960   # 0.9 inches
        
        # Credit growth values (3-month, 6-month, 12-month)
        if include_data_transfer:
            credit_growth_x_positions = [0.88, 1.61, 2.34]  # inches (3 charts layout)
        else:
            credit_growth_x_positions = [1.71, 2.44, 3.17]  # inches (2 charts layout)
        credit_growth_values = [credit_growth_3mo, credit_growth_6mo, credit_growth_12mo]
        
        for idx, (x_pos, growth_val) in enumerate(zip(credit_growth_x_positions, credit_growth_values)):
            x_emu = int(x_pos * 914400)
            # Determine color based on positive (green) or negative/zero (red) values
            if growth_val > 0:
                text_color = {'red': 0.157, 'green': 0.655, 'blue': 0.271}  # Green (#28a745)
            else:
                text_color = {'red': 0.863, 'green': 0.208, 'blue': 0.271}  # Red (#dc3545)
            
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'cred_val_{idx}_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': text_box_height_emu, 'unit': 'EMU'},
                                'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': x_emu,
                                'translateY': growth_values_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'cred_val_{idx}_{slide_id}',
                        'text': f'{growth_val:.1f}%',
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'cred_val_{idx}_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 11, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': text_color
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': True
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'cred_val_{idx}_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Storage growth values
        if include_data_transfer:
            storage_growth_x_positions = [3.86, 4.58, 5.31]  # inches (3 charts layout)
        else:
            storage_growth_x_positions = [6.41, 7.13, 7.86]  # inches (2 charts layout)
        storage_growth_values = [storage_growth_3mo, storage_growth_6mo, storage_growth_12mo]
        
        for idx, (x_pos, growth_val) in enumerate(zip(storage_growth_x_positions, storage_growth_values)):
            x_emu = int(x_pos * 914400)
            # Determine color based on positive (green) or negative/zero (red) values
            if growth_val > 0:
                text_color = {'red': 0.157, 'green': 0.655, 'blue': 0.271}  # Green (#28a745)
            else:
                text_color = {'red': 0.863, 'green': 0.208, 'blue': 0.271}  # Red (#dc3545)
            
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'stor_val_{idx}_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': text_box_height_emu, 'unit': 'EMU'},
                                'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': x_emu,
                                'translateY': growth_values_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'stor_val_{idx}_{slide_id}',
                        'text': f'{growth_val:.1f}%',
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'stor_val_{idx}_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 11, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': text_color
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': True
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'stor_val_{idx}_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Data transfer growth values (only if data transfer is included)
        if include_data_transfer:
            data_transfer_growth_x_positions = [6.82, 7.55, 8.28]  # inches
            data_transfer_growth_values = [data_transfer_growth_3mo, data_transfer_growth_6mo, data_transfer_growth_12mo]
            
            for idx, (x_pos, growth_val) in enumerate(zip(data_transfer_growth_x_positions, data_transfer_growth_values)):
                x_emu = int(x_pos * 914400)
                # Determine color based on positive (green) or negative/zero (red) values
                if growth_val > 0:
                    text_color = {'red': 0.157, 'green': 0.655, 'blue': 0.271}  # Green (#28a745)
                else:
                    text_color = {'red': 0.863, 'green': 0.208, 'blue': 0.271}  # Red (#dc3545)
                
                chart_requests.extend([
                    {
                        'createShape': {
                            'objectId': f'tran_val_{idx}_{slide_id}',
                            'shapeType': 'TEXT_BOX',
                            'elementProperties': {
                                'pageObjectId': slide_id,
                                'size': {
                                    'height': {'magnitude': text_box_height_emu, 'unit': 'EMU'},
                                    'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                                },
                                'transform': {
                                    'scaleX': 1,
                                    'scaleY': 1,
                                    'translateX': x_emu,
                                    'translateY': growth_values_y_emu,
                                    'unit': 'EMU'
                                }
                            }
                        }
                    },
                    {
                        'insertText': {
                            'objectId': f'tran_val_{idx}_{slide_id}',
                            'text': f'{growth_val:.1f}%',
                            'insertionIndex': 0
                        }
                    },
                    {
                        'updateTextStyle': {
                            'objectId': f'tran_val_{idx}_{slide_id}',
                            'style': {
                                'fontSize': {'magnitude': 11, 'unit': 'PT'},
                                'foregroundColor': {
                                    'opaqueColor': {
                                        'rgbColor': text_color
                                    }
                                },
                                'fontFamily': 'Arial',
                                'bold': True
                            },
                            'fields': 'fontSize,foregroundColor,fontFamily,bold'
                        }
                    },
                    {
                        'updateParagraphStyle': {
                            'objectId': f'tran_val_{idx}_{slide_id}',
                            'style': {
                                'alignment': 'CENTER'
                            },
                            'fields': 'alignment'
                        }
                    }
                ])
        
        # Add growth period labels below the percentage values
        # Y position: 4.89 inches = 4,471,056 EMU
        growth_labels_y_emu = 4471056
        label_text_box_height_emu = 182880  # 0.2 inches
        
        # Credit growth labels
        credit_label_texts = ["3-Month Growth", "6-Month Growth", "12-Month Growth"]
        for idx, (x_pos, label_text) in enumerate(zip(credit_growth_x_positions, credit_label_texts)):
            x_emu = int(x_pos * 914400)
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'cred_lbl_{idx}_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': label_text_box_height_emu, 'unit': 'EMU'},
                                'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': x_emu,
                                'translateY': growth_labels_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'cred_lbl_{idx}_{slide_id}',
                        'text': label_text,
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'cred_lbl_{idx}_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 8, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': False
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'cred_lbl_{idx}_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Storage growth labels
        storage_label_texts = ["3-Month Growth", "6-Month Growth", "12-Month Growth"]
        for idx, (x_pos, label_text) in enumerate(zip(storage_growth_x_positions, storage_label_texts)):
            x_emu = int(x_pos * 914400)
            chart_requests.extend([
                {
                    'createShape': {
                        'objectId': f'stor_lbl_{idx}_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': label_text_box_height_emu, 'unit': 'EMU'},
                                'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': x_emu,
                                'translateY': growth_labels_y_emu,
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'stor_lbl_{idx}_{slide_id}',
                        'text': label_text,
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'stor_lbl_{idx}_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 8, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': False
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'stor_lbl_{idx}_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Data transfer growth labels (only if data transfer is included)
        if include_data_transfer:
            data_transfer_label_texts = ["3-Month Avg", "6-Month Avg", "12-Month Avg"]
            for idx, (x_pos, label_text) in enumerate(zip(data_transfer_growth_x_positions, data_transfer_label_texts)):
                x_emu = int(x_pos * 914400)
                chart_requests.extend([
                    {
                        'createShape': {
                            'objectId': f'tran_lbl_{idx}_{slide_id}',
                            'shapeType': 'TEXT_BOX',
                            'elementProperties': {
                                'pageObjectId': slide_id,
                                'size': {
                                    'height': {'magnitude': label_text_box_height_emu, 'unit': 'EMU'},
                                    'width': {'magnitude': text_box_width_emu, 'unit': 'EMU'}
                                },
                                'transform': {
                                    'scaleX': 1,
                                    'scaleY': 1,
                                    'translateX': x_emu,
                                    'translateY': growth_labels_y_emu,
                                    'unit': 'EMU'
                                }
                            }
                        }
                    },
                    {
                        'insertText': {
                            'objectId': f'tran_lbl_{idx}_{slide_id}',
                            'text': label_text,
                            'insertionIndex': 0
                        }
                    },
                    {
                        'updateTextStyle': {
                            'objectId': f'tran_lbl_{idx}_{slide_id}',
                            'style': {
                                'fontSize': {'magnitude': 8, 'unit': 'PT'},
                                'foregroundColor': {
                                    'opaqueColor': {
                                        'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                                    }
                                },
                                'fontFamily': 'Arial',
                                'bold': False
                            },
                            'fields': 'fontSize,foregroundColor,fontFamily,bold'
                        }
                    },
                    {
                        'updateParagraphStyle': {
                            'objectId': f'tran_lbl_{idx}_{slide_id}',
                            'style': {
                                'alignment': 'CENTER'
                            },
                            'fields': 'alignment'
                        }
                    }
                ])
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': chart_requests}
        ).execute()
        
        # Add footer to data slide
        # self.add_footer_to_slide(presentation_id, slide_id, page_number=2)
        
        return slide_id
    
    def add_usage_overview_slide(self, presentation_id: str, spreadsheet_id: str, 
                                 chart_id: int, kpi_credits_change: float, 
                                 kpi_xp_change: float, kpi_period: str, 
                                 period_label: str) -> str:
        """
        Add Usage Overview and Unit Economics slide with KPIs and combo chart
        
        Args:
            presentation_id: ID of the presentation
            spreadsheet_id: ID of the source spreadsheet
            chart_id: ID of the combo chart in the spreadsheet
            kpi_credits_change: YoY change percentage for Credits/1K Jobs
            kpi_xp_change: YoY change percentage for XP Jobs
            kpi_period: Period label (e.g., "2025-11")
            period_label: "Month" or "Quarter"
            
        Returns:
            Slide ID
        """
        # Create a blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # 1 inch = 914400 EMU
        # Title: "Usage Overview and Unit Economics" - same format as slide 1
        content_requests = [
            {
                'createShape': {
                    'objectId': f'main_title_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 2743200, 'unit': 'EMU'},  # 3 inches
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}   # 9 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 457200,   # 0.5 inch
                            'translateY': 128016,   # 0.14 inch
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'main_title_{slide_id}',
                    'text': 'Usage Overview and Unit Economics',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 18, 'unit': 'PT'},
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,bold,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'alignment': 'START'
                    },
                    'fields': 'alignment'
                }
            }
        ]
        
        # KPI 1: Credits/1K Jobs (X=2.19", Y=1.27")
        # Red if positive (bad), Green if negative (good)
        kpi1_arrow = "↑" if kpi_credits_change > 0 else "↓"
        kpi1_color = {'red': 0.863, 'green': 0.208, 'blue': 0.271} if kpi_credits_change > 0 else {'red': 0.157, 'green': 0.655, 'blue': 0.271}
        kpi1_text = f"{kpi1_arrow} {abs(kpi_credits_change):.1f}%"
        
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi1_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},  # 0.4 inches
                            'width': {'magnitude': 1828800, 'unit': 'EMU'}   # 2 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(2.19 * 914400),  # 2.19 inches
                            'translateY': int(1.27 * 914400),  # 1.27 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi1_{slide_id}',
                    'text': kpi1_text,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi1_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 18, 'unit': 'PT'},
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': kpi1_color
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,bold,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi1_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # KPI 2: XP Jobs (X=5.09", Y=1.27")
        # Green if positive (good), Red if negative (bad)
        kpi2_arrow = "↑" if kpi_xp_change > 0 else "↓"
        kpi2_color = {'red': 0.157, 'green': 0.655, 'blue': 0.271} if kpi_xp_change > 0 else {'red': 0.863, 'green': 0.208, 'blue': 0.271}
        kpi2_text = f"{kpi2_arrow} {abs(kpi_xp_change):.1f}%"
        
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi2_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},
                            'width': {'magnitude': 1828800, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(5.09 * 914400),  # 5.09 inches
                            'translateY': int(1.27 * 914400),  # 1.27 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi2_{slide_id}',
                    'text': kpi2_text,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi2_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 18, 'unit': 'PT'},
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': kpi2_color
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,bold,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi2_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Subtitle 1: "Credits/1K Jobs vs Same {period_label} LY {period}" (X=2.12", Y=1.67")
        kpi1_subtitle = f"Credits/1K Jobs vs Same {period_label} LY\n{kpi_period}"
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'subtitle1_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 228600, 'unit': 'EMU'},  # 0.25 inches
                            'width': {'magnitude': 1828800, 'unit': 'EMU'}   # 2 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(2.12 * 914400),  # 2.12 inches
                            'translateY': int(1.67 * 914400),  # 1.67 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'subtitle1_{slide_id}',
                    'text': kpi1_subtitle,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'subtitle1_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 8, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'subtitle1_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Subtitle 2: "XP Jobs vs Same {period_label} LY {period}" (X=5.09", Y=1.67")
        kpi2_subtitle = f"XP Jobs vs Same {period_label} LY\n{kpi_period}"
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'subtitle2_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 228600, 'unit': 'EMU'},
                            'width': {'magnitude': 1828800, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': int(5.09 * 914400),  # 5.09 inches
                            'translateY': int(1.67 * 914400),  # 1.67 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'subtitle2_{slide_id}',
                    'text': kpi2_subtitle,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'subtitle2_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 8, 'unit': 'PT'},
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'subtitle2_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': content_requests}
        ).execute()
        
        # Add the combo chart (X=0.5", Y=2.24", Width=8.99", Height=3")
        chart_requests = [{
            'createSheetsChart': {
                'spreadsheetId': spreadsheet_id,
                'chartId': chart_id,
                'linkingMode': 'LINKED',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': int(3.0 * 914400), 'unit': 'EMU'},   # 3 inches
                        'width': {'magnitude': int(8.99 * 914400), 'unit': 'EMU'}    # 8.99 inches
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': int(0.5 * 914400),   # 0.5 inch
                        'translateY': int(2.24 * 914400),  # 2.24 inches
                        'unit': 'EMU'
                    }
                }
            }
        }]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': chart_requests}
        ).execute()
        
        return slide_id
    
    def add_chart_slide(self, presentation_id: str, title: str, chart_image_data: bytes, 
                       chart_title: str = "") -> str:
        """
        Add a slide with a chart - attempts image embedding, falls back to note
        
        Args:
            presentation_id: ID of the presentation
            title: Slide title
            chart_image_data: Image data as bytes (PNG format)
            chart_title: Optional chart title
            
        Returns:
            Slide ID
        """
        # Create a blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Add title
        title_requests = [{
            'createShape': {
                'objectId': f'title_{slide_id}',
                'shapeType': 'TEXT_BOX',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': 50, 'unit': 'PT'},
                        'width': {'magnitude': 650, 'unit': 'PT'}
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': 25,
                        'translateY': 20,
                        'unit': 'PT'
                    }
                }
            }
        }, {
            'insertText': {
                'objectId': f'title_{slide_id}',
                'text': title,
                'insertionIndex': 0
            }
        }, {
            'updateTextStyle': {
                'objectId': f'title_{slide_id}',
                'style': {
                    'fontSize': {
                        'magnitude': 24,
                        'unit': 'PT'
                    },
                    'bold': True
                },
                'fields': 'fontSize,bold'
            }
        }]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': title_requests}
        ).execute()
        
        # Add informational note (since image embedding often fails in corporate environments)
        note_requests = [{
            'createShape': {
                'objectId': f'note_{slide_id}',
                'shapeType': 'TEXT_BOX',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': 350, 'unit': 'PT'},
                        'width': {'magnitude': 600, 'unit': 'PT'}
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': 60,
                        'translateY': 100,
                        'unit': 'PT'
                    }
                }
            }
        }, {
            'insertText': {
                'objectId': f'note_{slide_id}',
                'text': f'📊 {title}\n\n✓ Chart data has been processed\n\n✓ See the Data Summary Table for detailed information\n\nNote: Chart visualizations are available in your local environment. Due to organizational security policies, chart images cannot be embedded in shared presentations.',
                'insertionIndex': 0
            }
        }, {
            'updateTextStyle': {
                'objectId': f'note_{slide_id}',
                'style': {
                    'fontSize': {
                        'magnitude': 14,
                        'unit': 'PT'
                    }
                },
                'textRange': {
                    'type': 'ALL'
                },
                'fields': 'fontSize'
            }
        }]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': note_requests}
        ).execute()
        
        return slide_id
    
    def add_table_slide(self, presentation_id: str, title: str, df: pd.DataFrame) -> str:
        """
        Add a slide with a table from a DataFrame
        
        Args:
            presentation_id: ID of the presentation
            title: Slide title
            df: Pandas DataFrame to display as table
            
        Returns:
            Slide ID
        """
        # Create a blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # Limit table size for readability
        df_display = df.head(10) if len(df) > 10 else df
        rows = len(df_display) + 1  # +1 for header
        cols = len(df_display.columns)
        
        # Create table - positioned at 1 inch from top, 4.0 inches height (same as charts)
        requests = [
            {
                'createTable': {
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 288, 'unit': 'PT'},  # 4.0 inches
                            'width': {'magnitude': 600, 'unit': 'PT'}    # Good table width
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 60,   # Center: (720 - 600) / 2
                            'translateY': 72,   # 1 inch from top
                            'unit': 'PT'
                        }
                    },
                    'rows': rows,
                    'columns': cols
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        table_id = response['replies'][0]['createTable']['objectId']
        
        # Populate table with data
        requests = []
        
        # Add header
        for col_idx, col_name in enumerate(df_display.columns):
            requests.append({
                'insertText': {
                    'objectId': table_id,
                    'cellLocation': {
                        'rowIndex': 0,
                        'columnIndex': col_idx
                    },
                    'text': str(col_name),
                    'insertionIndex': 0
                }
            })
        
        # Add data rows
        for row_idx, row in enumerate(df_display.itertuples(index=False), start=1):
            for col_idx, value in enumerate(row):
                requests.append({
                    'insertText': {
                        'objectId': table_id,
                        'cellLocation': {
                            'rowIndex': row_idx,
                            'columnIndex': col_idx
                        },
                        'text': str(value),
                        'insertionIndex': 0
                    }
                })
        
        # Add title text box - consistent with chart slides
        requests.append({
            'createShape': {
                'objectId': f'title_{slide_id}',
                'shapeType': 'TEXT_BOX',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': 50, 'unit': 'PT'},
                        'width': {'magnitude': 650, 'unit': 'PT'}
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': 35,   # Center: (720 - 650) / 2
                        'translateY': 10,   # At top, consistent with chart slides
                        'unit': 'PT'
                    }
                }
            }
        })
        
        requests.append({
            'insertText': {
                'objectId': f'title_{slide_id}',
                'text': title,
                'insertionIndex': 0
            }
        })
        
        # Format title text
        requests.append({
            'updateTextStyle': {
                'objectId': f'title_{slide_id}',
                'style': {
                    'fontSize': {
                        'magnitude': 28,
                        'unit': 'PT'
                    },
                    'bold': True
                },
                'fields': 'fontSize,bold'
            }
        })
        
        # Center align title
        requests.append({
            'updateParagraphStyle': {
                'objectId': f'title_{slide_id}',
                'style': {
                    'alignment': 'CENTER'
                },
                'fields': 'alignment'
            }
        })
        
        if requests:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
        
        return slide_id
    
    def add_forecast_slide(self, presentation_id: str, spreadsheet_id: str,
                          chart_id: int, years_to_project: int, chart_title: str = "",
                          total_cost: float = 0, avg_annual_cost: float = 0,
                          total_credit_cost: float = 0, yearly_costs: list = None,
                          include_data_transfer: bool = False,
                          yearly_breakdown_sheet_id: int = None) -> str:
        """
        Add forecast slide with stacked bar chart and cost breakdown table
        
        Args:
            presentation_id: ID of the presentation
            spreadsheet_id: ID of the source spreadsheet
            chart_id: ID of the stacked bar chart in the spreadsheet
            years_to_project: Number of years projected (e.g., 3, 5)
            chart_title: Chart title text to display above the chart
            total_cost: Total cost across all years
            avg_annual_cost: Average annual cost
            total_credit_cost: Total credit cost
            yearly_costs: List of yearly cost breakdowns
            include_data_transfer: Whether data transfer costs are included
            yearly_breakdown_sheet_id: Sheet ID for yearly breakdown table data
            
        Returns:
            Slide ID
        """
        # Create a blank slide
        requests = [
            {
                'createSlide': {
                    'slideLayoutReference': {
                        'predefinedLayout': 'BLANK'
                    }
                }
            }
        ]
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        slide_id = response['replies'][0]['createSlide']['objectId']
        
        # 1 inch = 914400 EMU
        # Title: "{years}Y Forecast - Monthly Consumption" - same format as previous slides
        title_text = f"{years_to_project}Y Forecast - Monthly Consumption"
        
        content_requests = [
            {
                'createShape': {
                    'objectId': f'main_title_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 2743200, 'unit': 'EMU'},  # 3 inches
                            'width': {'magnitude': 8229600, 'unit': 'EMU'}   # 9 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 457200,   # 0.5 inch
                            'translateY': 128016,   # 0.14 inch
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'main_title_{slide_id}',
                    'text': title_text,
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'fontSize': {'magnitude': 18, 'unit': 'PT'},
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}  # Black
                            }
                        },
                        'fontFamily': 'Arial'
                    },
                    'fields': 'fontSize,bold,foregroundColor,fontFamily'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'main_title_{slide_id}',
                    'style': {
                        'alignment': 'START'
                    },
                    'fields': 'alignment'
                }
            }
        ]
        
        # Add chart title text box (separate from chart)
        # Position: X=0.5", Y=0.5"
        if chart_title:
            content_requests.extend([
                {
                    'createShape': {
                        'objectId': f'chart_title_{slide_id}',
                        'shapeType': 'TEXT_BOX',
                        'elementProperties': {
                            'pageObjectId': slide_id,
                            'size': {
                                'height': {'magnitude': 228600, 'unit': 'EMU'},  # 0.25 inches
                                'width': {'magnitude': 8229600, 'unit': 'EMU'}   # 9 inches
                            },
                            'transform': {
                                'scaleX': 1,
                                'scaleY': 1,
                                'translateX': 457200,   # 0.5 inch
                                'translateY': 457200,   # 0.5 inch
                                'unit': 'EMU'
                            }
                        }
                    }
                },
                {
                    'insertText': {
                        'objectId': f'chart_title_{slide_id}',
                        'text': chart_title,
                        'insertionIndex': 0
                    }
                },
                {
                    'updateTextStyle': {
                        'objectId': f'chart_title_{slide_id}',
                        'style': {
                            'fontSize': {'magnitude': 10, 'unit': 'PT'},
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': {'red': 0.161, 'green': 0.710, 'blue': 0.910}  # #29B5E8
                                }
                            },
                            'fontFamily': 'Arial',
                            'bold': True
                        },
                        'fields': 'fontSize,foregroundColor,fontFamily,bold'
                    }
                },
                {
                    'updateParagraphStyle': {
                        'objectId': f'chart_title_{slide_id}',
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'fields': 'alignment'
                    }
                }
            ])
        
        # Add chart
        # Position: X=0.5", Y=0.75"
        # Size: Width=9", Height=2.4"
        content_requests.append({
            'createSheetsChart': {
                'spreadsheetId': spreadsheet_id,
                'chartId': chart_id,
                'linkingMode': 'LINKED',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': 2194560, 'unit': 'EMU'},  # 2.4 inches
                        'width': {'magnitude': 8229600, 'unit': 'EMU'}    # 9 inches
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': 457200,   # 0.5 inch
                        'translateY': 685800,   # 0.75 inches
                        'unit': 'EMU'
                    }
                }
            }
        })
        
        # Add KPI boxes below the chart
        # KPI Box 1: Total Cost Value (X=0.74", Y=3.2", Bold)
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_total_cost_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},  # 0.4 inches
                            'width': {'magnitude': 2211648, 'unit': 'EMU'}   # 2.42 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 676656,   # 0.74 inch
                            'translateY': 2926080,  # 3.2 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_total_cost_{slide_id}',
                    'text': f"${total_cost:,.0f}",
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_total_cost_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 14, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.161, 'green': 0.710, 'blue': 0.910}  # #29B5E8
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,bold,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_total_cost_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Add label below Total Cost KPI (X=1.28", Y=3.53")
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_total_cost_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                            'width': {'magnitude': 1124712, 'unit': 'EMU'}   # 1.23 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 1170432,  # 1.28 inches
                            'translateY': 3227592,  # 3.53 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_total_cost_label_{slide_id}',
                    'text': 'Total Cost',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_total_cost_label_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 9, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_total_cost_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # KPI Box 2: Avg Annual Value (X=0.14", Y=3.79", Bold)
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_avg_annual_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},  # 0.4 inches
                            'width': {'magnitude': 1873800, 'unit': 'EMU'}   # 2.05 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 128016,   # 0.14 inch
                            'translateY': 3465456,  # 3.79 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_avg_annual_{slide_id}',
                    'text': f"${avg_annual_cost:,.0f}",
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_avg_annual_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 14, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.459, 'green': 0.804, 'blue': 0.843}  # #75CDD7
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,bold,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_avg_annual_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Add label below Avg Annual KPI (X=0.49", Y=4.19")
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_avg_annual_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                            'width': {'magnitude': 1024128, 'unit': 'EMU'}   # 1.12 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 448056,   # 0.49 inch
                            'translateY': 3831336,  # 4.19 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_avg_annual_label_{slide_id}',
                    'text': 'Avg Annual',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_avg_annual_label_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 9, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_avg_annual_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # KPI Box 3: Credit Cost Value (X=1.75", Y=3.79", Bold)
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_credit_cost_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 365760, 'unit': 'EMU'},  # 0.4 inches
                            'width': {'magnitude': 1937808, 'unit': 'EMU'}   # 2.12 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 1600200,  # 1.75 inches
                            'translateY': 3465456,  # 3.79 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_credit_cost_{slide_id}',
                    'text': f"${total_credit_cost:,.0f}",
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_credit_cost_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 14, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'bold': True,
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.357, 'green': 0.357, 'blue': 0.357}  # #5B5B5B
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,bold,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_credit_cost_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Add label below Credit Cost KPI (X=2.07", Y=4.19")
        content_requests.extend([
            {
                'createShape': {
                    'objectId': f'kpi_credit_cost_label_{slide_id}',
                    'shapeType': 'TEXT_BOX',
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': 274320, 'unit': 'EMU'},  # 0.3 inches
                            'width': {'magnitude': 1252728, 'unit': 'EMU'}   # 1.37 inches
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': 1892808,  # 2.07 inches
                            'translateY': 3831336,  # 4.19 inches
                            'unit': 'EMU'
                        }
                    }
                }
            },
            {
                'insertText': {
                    'objectId': f'kpi_credit_cost_label_{slide_id}',
                    'text': 'Credit Cost',
                    'insertionIndex': 0
                }
            },
            {
                'updateTextStyle': {
                    'objectId': f'kpi_credit_cost_label_{slide_id}',
                    'textRange': {
                        'type': 'ALL'
                    },
                    'style': {
                        'fontSize': {'magnitude': 9, 'unit': 'PT'},
                        'fontFamily': 'Arial',
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                            }
                        }
                    },
                    'fields': 'fontSize,fontFamily,foregroundColor'
                }
            },
            {
                'updateParagraphStyle': {
                    'objectId': f'kpi_credit_cost_label_{slide_id}',
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'fields': 'alignment'
                }
            }
        ])
        
        # Add Year-by-Year Breakdown table (width=5.9", X=3.68", Y=3.0")
        if yearly_costs:
            # Table dimensions
            table_x = 3365952  # 3.68 inches
            table_y = 2743200  # 3.0 inches
            table_width = 5393760  # 5.9 inches
            
            # Use fixed row height for compact display
            row_height = 228600  # 0.25 inches per row (compact)
            
            # Determine number of rows and columns
            num_data_rows = len(yearly_costs)
            num_rows = num_data_rows + 1  # +1 for header
            table_height = row_height * num_rows
            
            # Determine number of columns based on include_data_transfer
            if include_data_transfer:
                num_columns = 5  # Year, Credit Cost, Storage Cost, Data Transfer Cost, Total Cost
            else:
                num_columns = 4  # Year, Credit Cost, Storage Cost, Total Cost
            
            # Create table
            table_id = f'yearly_breakdown_table_{slide_id}'
            content_requests.append({
                'createTable': {
                    'objectId': table_id,
                    'elementProperties': {
                        'pageObjectId': slide_id,
                        'size': {
                            'height': {'magnitude': table_height, 'unit': 'EMU'},
                            'width': {'magnitude': table_width, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': table_x,
                            'translateY': table_y,
                            'unit': 'EMU'
                        }
                    },
                    'rows': num_rows,
                    'columns': num_columns
                }
            })
            
            # Populate table with data
            # Header row
            header_texts = ['Year', 'Credit Cost ($)', 'Storage Cost ($)']
            if include_data_transfer:
                header_texts.append('Data Transfer Cost ($)')
            header_texts.append('Total Cost ($)')
            
            for col_idx, header_text in enumerate(header_texts):
                content_requests.extend([
                    {
                        'insertText': {
                            'objectId': table_id,
                            'cellLocation': {
                                'rowIndex': 0,
                                'columnIndex': col_idx
                            },
                            'text': header_text,
                            'insertionIndex': 0
                        }
                    },
                        {
                            'updateTextStyle': {
                                'objectId': table_id,
                                'cellLocation': {
                                    'rowIndex': 0,
                                    'columnIndex': col_idx
                                },
                                'style': {
                                    'fontSize': {'magnitude': 8, 'unit': 'PT'},
                                    'fontFamily': 'Arial',
                                    'bold': True,
                                    'foregroundColor': {
                                        'opaqueColor': {
                                            'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                                        }
                                    }
                                },
                                'fields': 'fontSize,fontFamily,bold,foregroundColor'
                            }
                        },
                        {
                            'updateParagraphStyle': {
                                'objectId': table_id,
                                'cellLocation': {
                                    'rowIndex': 0,
                                    'columnIndex': col_idx
                                },
                                'style': {
                                    'spaceAbove': {'magnitude': 0, 'unit': 'PT'},
                                    'spaceBelow': {'magnitude': 0, 'unit': 'PT'},
                                    'lineSpacing': 100
                                },
                                'fields': 'spaceAbove,spaceBelow,lineSpacing'
                            }
                        }
                ])
            
            # Data rows
            for row_idx, year_data in enumerate(yearly_costs, start=1):
                row_values = [
                    f"Year {year_data['year']}",
                    f"${year_data['credit_cost']:,.0f}",
                    f"${year_data['storage_cost']:,.0f}"
                ]
                if include_data_transfer:
                    row_values.append(f"${year_data['data_transfer_cost']:,.0f}")
                row_values.append(f"${year_data['total_cost']:,.0f}")
                
                for col_idx, cell_value in enumerate(row_values):
                    content_requests.extend([
                        {
                            'insertText': {
                                'objectId': table_id,
                                'cellLocation': {
                                    'rowIndex': row_idx,
                                    'columnIndex': col_idx
                                },
                                'text': cell_value,
                                'insertionIndex': 0
                            }
                        },
                        {
                            'updateTextStyle': {
                                'objectId': table_id,
                                'cellLocation': {
                                    'rowIndex': row_idx,
                                    'columnIndex': col_idx
                                },
                                'style': {
                                    'fontSize': {'magnitude': 8, 'unit': 'PT'},
                                    'fontFamily': 'Arial',
                                    'foregroundColor': {
                                        'opaqueColor': {
                                            'rgbColor': {'red': 0.0, 'green': 0.0, 'blue': 0.0}
                                        }
                                    }
                                },
                                'fields': 'fontSize,fontFamily,foregroundColor'
                            }
                        },
                        {
                            'updateParagraphStyle': {
                                'objectId': table_id,
                                'cellLocation': {
                                    'rowIndex': row_idx,
                                    'columnIndex': col_idx
                                },
                                'style': {
                                    'spaceAbove': {'magnitude': 0, 'unit': 'PT'},
                                    'spaceBelow': {'magnitude': 0, 'unit': 'PT'},
                                    'lineSpacing': 100
                                },
                                'fields': 'spaceAbove,spaceBelow,lineSpacing'
                            }
                        }
                    ])
        
        # Execute all requests
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': content_requests}
        ).execute()
        
        # Add footer to forecast slide (page 5: Cover, Historical, Detailed Analysis, Usage Overview, Forecast)
        # self.add_footer_to_slide(presentation_id, slide_id, page_number=5)
        
        return slide_id
    
    def get_presentation_url(self, presentation_id: str) -> str:
        """Get the URL for a presentation"""
        return f"https://docs.google.com/presentation/d/{presentation_id}/edit"

    def refresh_all_linked_charts(self, presentation_id: str) -> int:
        """
        Refresh all linked charts in the presentation with latest data from Google Sheets.
        
        This method finds all charts that are linked to Google Sheets and triggers
        a refresh to pull the latest data from the source spreadsheets.
        
        Args:
            presentation_id: ID of the presentation
            
        Returns:
            Number of charts refreshed
        """
        # Get the presentation to find all linked charts
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        # Find all linked chart object IDs
        chart_object_ids = []
        
        for slide in presentation.get('slides', []):
            for element in slide.get('pageElements', []):
                # Check if this element is a linked Sheets chart
                if 'sheetsChart' in element:
                    sheets_chart = element['sheetsChart']
                    # Only refresh charts that are linked (not images)
                    chart_props = sheets_chart.get('sheetsChartProperties', {})
                    if chart_props.get('chartImageProperties') is None:
                        # This is a linked chart, not an image
                        chart_object_ids.append(element['objectId'])
        
        if not chart_object_ids:
            return 0
        
        # Create refresh requests for all linked charts
        refresh_requests = []
        for object_id in chart_object_ids:
            refresh_requests.append({
                'refreshSheetsChart': {
                    'objectId': object_id
                }
            })
        
        # Execute the refresh
        if refresh_requests:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': refresh_requests}
            ).execute()
        
        return len(chart_object_ids)
    
    def get_linked_charts_info(self, presentation_id: str) -> list:
        """
        Get information about all linked charts in the presentation.
        
        Args:
            presentation_id: ID of the presentation
            
        Returns:
            List of dictionaries with chart information
        """
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        charts_info = []
        
        for slide_index, slide in enumerate(presentation.get('slides', []), 1):
            for element in slide.get('pageElements', []):
                if 'sheetsChart' in element:
                    sheets_chart = element['sheetsChart']
                    charts_info.append({
                        'slide_number': slide_index,
                        'object_id': element['objectId'],
                        'spreadsheet_id': sheets_chart.get('spreadsheetId'),
                        'chart_id': sheets_chart.get('chartId'),
                        'content_url': sheets_chart.get('contentUrl', 'N/A')
                    })
        
        return charts_info
    
    # ==================== TEMPLATE-BASED METHODS ====================
    
    def copy_template(self, template_id: str, new_name: str, folder_id: str = None) -> Dict[str, Any]:
        """
        Copy an existing template to create a new presentation.
        
        Automatically converts PowerPoint files to native Google Slides format.
        Creates directly in the target folder (works with service accounts).
        
        Args:
            template_id: ID of the template presentation to copy
            new_name: Name for the new presentation
            folder_id: Optional folder ID to place the copy in
            
        Returns:
            Dictionary with presentation_id and url
        """
        # Copy the template directly to the target folder
        # Force conversion to native Google Slides format (required for batchUpdate to work)
        copy_body = {
            'name': new_name,
            'mimeType': 'application/vnd.google-apps.presentation'  # Convert PPTX to Google Slides
        }
        if folder_id:
            copy_body['parents'] = [folder_id]
        
        # Use supportsAllDrives=True for Shared Drive support
        copied_file = self.drive_service.files().copy(
            fileId=template_id,
            body=copy_body,
            supportsAllDrives=True
        ).execute()
        
        presentation_id = copied_file.get('id')
        
        # Wait for the conversion to complete
        time.sleep(2)
        
        return {
            'presentation_id': presentation_id,
            'url': f"https://docs.google.com/presentation/d/{presentation_id}/edit"
        }
    
    def move_to_shared_drive(self, file_id: str, folder_id: str) -> bool:
        """
        Move a file from My Drive to a Shared Drive folder.
        Call this AFTER all modifications are complete.
        
        Args:
            file_id: ID of the file to move
            folder_id: Destination Shared Drive folder ID
            
        Returns:
            True if successful
        """
        if not folder_id:
            return True  # No move needed
            
        try:
            # Get current parents
            file = self.drive_service.files().get(
                fileId=file_id,
                fields='parents',
                supportsAllDrives=True
            ).execute()
            
            previous_parents = ",".join(file.get('parents', []))
            
            # Move to Shared Drive folder
            self.drive_service.files().update(
                fileId=file_id,
                addParents=folder_id,
                removeParents=previous_parents,
                supportsAllDrives=True,
                fields='id, parents'
            ).execute()
            
            return True
        except HttpError as e:
            print(f"Warning: Could not move file to Shared Drive: {e}")
            return False
    
    def replace_text_placeholders(self, presentation_id: str, replacements: Dict[str, str]) -> int:
        """
        Replace placeholder text throughout the presentation.
        
        Use placeholders like {{CUSTOMER_NAME}}, {{TOTAL_CREDITS}}, etc. in your template.
        
        Args:
            presentation_id: ID of the presentation
            replacements: Dictionary mapping placeholder text to replacement values
                         e.g., {'{{CUSTOMER_NAME}}': 'Acme Corp', '{{DATE}}': 'Dec 2024'}
            
        Returns:
            Number of replacements made
        """
        requests = []
        for placeholder, replacement in replacements.items():
            requests.append({
                'replaceAllText': {
                    'containsText': {
                        'text': placeholder,
                        'matchCase': True
                    },
                    'replaceText': str(replacement)
                }
            })
        
        if not requests:
            return 0
        
        response = self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        # Count total replacements
        total_replacements = 0
        for reply in response.get('replies', []):
            if 'replaceAllText' in reply:
                total_replacements += reply['replaceAllText'].get('occurrencesChanged', 0)
        
        return total_replacements
    
    def replace_text_with_color(self, presentation_id: str, placeholder: str, 
                                 value: float, format_str: str = "{:.1f}%") -> bool:
        """
        Replace placeholder text with a value and apply conditional color formatting.
        Red for negative values, green for positive/zero values.
        
        Args:
            presentation_id: ID of the presentation
            placeholder: Placeholder text to replace (e.g., "{{CREDIT_GROWTH_3MO}}")
            value: Numeric value (will determine color)
            format_str: Format string for the value (default: "{:.1f}%")
            
        Returns:
            True if replacement was successful
        """
        # Format the replacement text
        replacement_text = format_str.format(value)
        
        # Define colors: Red for negative, Green for positive
        if value < 0:
            color = {'red': 0.8, 'green': 0.2, 'blue': 0.2}  # Red
        else:
            color = {'red': 0.2, 'green': 0.6, 'blue': 0.2}  # Green
        
        # First, get the presentation to find where the placeholder is
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        # Find all shapes containing the placeholder text and their details
        updates = []
        
        for slide in presentation.get('slides', []):
            for element in slide.get('pageElements', []):
                if 'shape' in element and 'text' in element.get('shape', {}):
                    shape = element['shape']
                    text_elements = shape.get('text', {}).get('textElements', [])
                    
                    # Check if this shape contains our placeholder
                    full_text = ''
                    for te in text_elements:
                        if 'textRun' in te:
                            full_text += te['textRun'].get('content', '')
                    
                    if placeholder in full_text:
                        object_id = element['objectId']
                        
                        # Find the start index of the placeholder
                        start_index = full_text.find(placeholder)
                        end_index = start_index + len(placeholder)
                        
                        updates.append({
                            'object_id': object_id,
                            'start_index': start_index,
                            'end_index': end_index,
                            'replacement_text': replacement_text
                        })
        
        if not updates:
            # Fallback to simple replacement if not found
            self.replace_text_placeholders(presentation_id, {placeholder: replacement_text})
            return True
        
        # Process each found placeholder
        for update in updates:
            requests = [
                # Delete the placeholder text
                {
                    'deleteText': {
                        'objectId': update['object_id'],
                        'textRange': {
                            'type': 'FIXED_RANGE',
                            'startIndex': update['start_index'],
                            'endIndex': update['end_index']
                        }
                    }
                },
                # Insert the replacement text
                {
                    'insertText': {
                        'objectId': update['object_id'],
                        'text': update['replacement_text'],
                        'insertionIndex': update['start_index']
                    }
                },
                # Apply color to the inserted text
                {
                    'updateTextStyle': {
                        'objectId': update['object_id'],
                        'textRange': {
                            'type': 'FIXED_RANGE',
                            'startIndex': update['start_index'],
                            'endIndex': update['start_index'] + len(update['replacement_text'])
                        },
                        'style': {
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': color
                                }
                            }
                        },
                        'fields': 'foregroundColor'
                    }
                }
            ]
            
            try:
                self.slides_service.presentations().batchUpdate(
                    presentationId=presentation_id,
                    body={'requests': requests}
                ).execute()
            except Exception as e:
                # If detailed replacement fails, fallback to simple replacement
                print(f"Color replacement failed for {placeholder}, using simple replacement: {e}")
                self.replace_text_placeholders(presentation_id, {placeholder: replacement_text})
        
        return True
    
    def replace_text_with_arrow_and_color(self, presentation_id: str, placeholder: str, 
                                           value: float, reverse_color: bool = False,
                                           format_str: str = "{:.1f}%") -> bool:
        """
        Replace placeholder text with a value including arrow and apply conditional color formatting.
        Arrow: ↑ for positive, ↓ for negative.
        Color logic:
            - Normal (reverse_color=False): positive = green (good), negative = red (bad)
            - Reversed (reverse_color=True): positive = red (bad), negative = green (good)
              Used for Credits/1K Jobs where lower is better.
        
        Args:
            presentation_id: ID of the presentation
            placeholder: Placeholder text to replace (e.g., "{{CREDIT_QUERY}}")
            value: Numeric value (will determine arrow direction and color)
            reverse_color: If True, reverses the color logic (positive=red, negative=green)
            format_str: Format string for the value (default: "{:.1f}%")
            
        Returns:
            True if replacement was successful
        """
        # Format the replacement text with arrow
        arrow = "↑" if value > 0 else "↓"
        replacement_text = f"{arrow} {format_str.format(abs(value))}"
        
        # Define colors based on logic
        if reverse_color:
            # Reversed: positive = red (bad), negative = green (good)
            if value > 0:
                color = {'red': 0.86, 'green': 0.21, 'blue': 0.27}  # #dc3545 Red
            else:
                color = {'red': 0.16, 'green': 0.65, 'blue': 0.27}  # #28a745 Green
        else:
            # Normal: positive = green (good), negative = red (bad)
            if value > 0:
                color = {'red': 0.16, 'green': 0.65, 'blue': 0.27}  # #28a745 Green
            else:
                color = {'red': 0.86, 'green': 0.21, 'blue': 0.27}  # #dc3545 Red
        
        # Get the presentation to find where the placeholder is
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        # Find all shapes containing the placeholder text
        updates = []
        
        for slide in presentation.get('slides', []):
            for element in slide.get('pageElements', []):
                if 'shape' in element and 'text' in element.get('shape', {}):
                    shape = element['shape']
                    text_elements = shape.get('text', {}).get('textElements', [])
                    
                    # Check if this shape contains our placeholder
                    full_text = ''
                    for te in text_elements:
                        if 'textRun' in te:
                            full_text += te['textRun'].get('content', '')
                    
                    if placeholder in full_text:
                        object_id = element['objectId']
                        start_index = full_text.find(placeholder)
                        end_index = start_index + len(placeholder)
                        
                        updates.append({
                            'object_id': object_id,
                            'start_index': start_index,
                            'end_index': end_index,
                            'replacement_text': replacement_text
                        })
        
        if not updates:
            # Fallback to simple replacement if not found
            self.replace_text_placeholders(presentation_id, {placeholder: replacement_text})
            return True
        
        # Process each found placeholder
        for update in updates:
            requests = [
                # Delete the placeholder text
                {
                    'deleteText': {
                        'objectId': update['object_id'],
                        'textRange': {
                            'type': 'FIXED_RANGE',
                            'startIndex': update['start_index'],
                            'endIndex': update['end_index']
                        }
                    }
                },
                # Insert the replacement text
                {
                    'insertText': {
                        'objectId': update['object_id'],
                        'text': update['replacement_text'],
                        'insertionIndex': update['start_index']
                    }
                },
                # Apply color to the inserted text
                {
                    'updateTextStyle': {
                        'objectId': update['object_id'],
                        'textRange': {
                            'type': 'FIXED_RANGE',
                            'startIndex': update['start_index'],
                            'endIndex': update['start_index'] + len(update['replacement_text'])
                        },
                        'style': {
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': color
                                }
                            }
                        },
                        'fields': 'foregroundColor'
                    }
                }
            ]
            
            try:
                self.slides_service.presentations().batchUpdate(
                    presentationId=presentation_id,
                    body={'requests': requests}
                ).execute()
            except Exception as e:
                print(f"Arrow+color replacement failed for {placeholder}: {e}")
                self.replace_text_placeholders(presentation_id, {placeholder: replacement_text})
        
        return True
    
    def get_element_by_text(self, presentation_id: str, search_text: str) -> dict:
        """
        Finds a page element (shape) by its text content.
        
        Args:
            presentation_id: ID of the presentation
            search_text: Text to search for in shape content
            
        Returns:
            Dictionary with element details (object_id, slide_id, size, transform) or None if not found
        """
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        for slide in presentation.get('slides', []):
            slide_id = slide.get('objectId')
            for element in slide.get('pageElements', []):
                if 'shape' in element:
                    shape = element['shape']
                    # Extract text content from shape
                    text_content = ''
                    if 'text' in shape:
                        for te in shape.get('text', {}).get('textElements', []):
                            if 'textRun' in te:
                                text_content += te['textRun'].get('content', '')
                    
                    if search_text in text_content:
                        return {
                            'object_id': element['objectId'],
                            'slide_id': slide_id,
                            'size': element.get('size', {}),
                            'transform': element.get('transform', {}),
                            'text': text_content.strip()
                        }
        
        return None
    
    def replace_shape_with_linked_chart(self, presentation_id: str, placeholder_text: str,
                                        spreadsheet_id: str, chart_id: int,
                                        width_inches: float = None, height_inches: float = None) -> bool:
        """
        Replace a placeholder shape (containing specific text) with a linked Google Sheets chart.
        The chart will be placed at the placeholder's position. If width/height are provided,
        the chart will be sized to those dimensions; otherwise it uses natural size from Sheets.
        
        In your template, create a shape (rectangle) with text like "{{CONSUMPTION_CHART}}"
        This method will replace it with an actual linked chart at that position.
        
        Args:
            presentation_id: ID of the presentation
            placeholder_text: Text in the shape to find (e.g., "{{CONSUMPTION_CHART}}")
            spreadsheet_id: ID of the Google Sheets spreadsheet containing the chart
            chart_id: ID of the chart in the spreadsheet
            width_inches: Optional explicit width in inches for the chart on slide
            height_inches: Optional explicit height in inches for the chart on slide
            
        Returns:
            True if replacement was successful
        """
        import uuid
        
        EMU_PER_INCH = 914400
        
        # Step 1: Get the presentation to find the placeholder shape
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        # Find the placeholder shape and get its properties
        placeholder_found = False
        shape_info = None
        
        for slide in presentation.get('slides', []):
            slide_id = slide.get('objectId')
            for element in slide.get('pageElements', []):
                if 'shape' in element:
                    shape = element['shape']
                    # Check if shape contains the placeholder text
                    text_content = ''
                    if 'text' in shape:
                        for te in shape.get('text', {}).get('textElements', []):
                            if 'textRun' in te:
                                text_content += te['textRun'].get('content', '')
                    
                    if placeholder_text in text_content:
                        # Found the placeholder! Get its size and transform
                        shape_info = {
                            'object_id': element['objectId'],
                            'slide_id': slide_id,
                            'size': element.get('size', {}),
                            'transform': element.get('transform', {})
                        }
                        placeholder_found = True
                        break
            if placeholder_found:
                break
        
        if not shape_info:
            print(f"Placeholder '{placeholder_text}' not found in presentation")
            return False
        
        # Step 2: Extract position from transform
        transform = shape_info['transform']
        translate_x = transform.get('translateX', 0)
        translate_y = transform.get('translateY', 0)
        
        # Generate unique object ID for the chart
        chart_object_id = f"chart_{uuid.uuid4().hex[:8]}"
        
        # Step 3: Build element properties with size from original shape
        # Get the original shape's size (required for proper chart placement)
        original_size = shape_info['size']
        original_width = original_size.get('width', {})
        original_height = original_size.get('height', {})
        
        # Use original shape size if no explicit size provided
        # Both width and height MUST be specified when size is included
        # NOTE: Always ensure 'unit' is never empty - Google Slides API returns UNIT_UNSPECIFIED error otherwise
        if width_inches is not None and height_inches is not None:
            chart_width = {'magnitude': width_inches * EMU_PER_INCH, 'unit': 'EMU'}
            chart_height = {'magnitude': height_inches * EMU_PER_INCH, 'unit': 'EMU'}
        elif original_width and original_height:
            # Use the original placeholder shape's size
            # Use 'or' to handle cases where unit might be empty string from API
            chart_width = {
                'magnitude': original_width.get('magnitude', 3000000),
                'unit': original_width.get('unit') or 'EMU'
            }
            chart_height = {
                'magnitude': original_height.get('magnitude', 2000000),
                'unit': original_height.get('unit') or 'EMU'
            }
        else:
            # Default fallback size (approx 4x3 inches)
            chart_width = {'magnitude': 4 * EMU_PER_INCH, 'unit': 'EMU'}
            chart_height = {'magnitude': 3 * EMU_PER_INCH, 'unit': 'EMU'}
        
        element_properties = {
            'pageObjectId': shape_info['slide_id'],
            'size': {
                'width': chart_width,
                'height': chart_height
            },
            'transform': {
                'scaleX': 1,
                'scaleY': 1,
                'translateX': translate_x,
                'translateY': translate_y,
                'unit': 'EMU'
            }
        }
        
        # Step 4: Delete the placeholder shape and create chart at same location
        requests = [
            # Delete the placeholder shape
            {
                'deleteObject': {
                    'objectId': shape_info['object_id']
                }
            },
            # Create the chart at the placeholder's position
            {
                'createSheetsChart': {
                    'objectId': chart_object_id,
                    'spreadsheetId': spreadsheet_id,
                    'chartId': chart_id,
                    'linkingMode': 'LINKED',
                    'elementProperties': element_properties
                }
            }
        ]
        
        try:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
            return True
        except Exception as e:
            print(f"Error replacing shape with chart: {e}")
            # Fallback to original method
            request = {
                'replaceAllShapesWithSheetsChart': {
                    'containsText': {
                        'text': placeholder_text,
                        'matchCase': True
                    },
                    'spreadsheetId': spreadsheet_id,
                    'chartId': chart_id,
                    'linkingMode': 'LINKED'
                }
            }
            
            response = self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': [request]}
            ).execute()
            
            for reply in response.get('replies', []):
                if 'replaceAllShapesWithSheetsChart' in reply:
                    return reply['replaceAllShapesWithSheetsChart'].get('occurrencesChanged', 0) > 0
            
            return False
    
    def replace_shape_with_table(self, presentation_id: str, placeholder_text: str,
                                  df: pd.DataFrame, header_bg_color: dict = None,
                                  font_size: int = 8, width_inches: float = None,
                                  height_inches: float = None, alternate_row_colors: bool = True) -> bool:
        """
        Replace a placeholder shape with a professionally styled table from a DataFrame.
        The table will be placed at the placeholder's position and sized to fit.
        
        Args:
            presentation_id: ID of the presentation
            placeholder_text: Text in the shape to find (e.g., "{{YEAR_BY_YEAR_COST}}")
            df: Pandas DataFrame to display as table
            header_bg_color: Optional RGB dict for header background (e.g., {'red': 0.16, 'green': 0.34, 'blue': 0.5})
            font_size: Font size in points (default: 8)
            width_inches: Optional width in inches (if None, uses placeholder size)
            height_inches: Optional height in inches (if None, uses placeholder size)
            alternate_row_colors: Whether to use alternating row colors (default: True)
            
        Returns:
            True if replacement was successful
        """
        import uuid
        
        EMU_PER_PT = 12700  # EMU per point
        EMU_PER_INCH = 914400  # EMU per inch
        
        # Step 1: Get the presentation to find the placeholder shape
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        # Find the placeholder shape and get its properties
        shape_info = None
        
        for slide in presentation.get('slides', []):
            slide_id = slide.get('objectId')
            for element in slide.get('pageElements', []):
                if 'shape' in element:
                    shape = element['shape']
                    text_content = ''
                    if 'text' in shape:
                        for te in shape.get('text', {}).get('textElements', []):
                            if 'textRun' in te:
                                text_content += te['textRun'].get('content', '')
                    
                    if placeholder_text in text_content:
                        shape_info = {
                            'object_id': element['objectId'],
                            'slide_id': slide_id,
                            'size': element.get('size', {}),
                            'transform': element.get('transform', {})
                        }
                        break
            if shape_info:
                break
        
        if not shape_info:
            print(f"Placeholder '{placeholder_text}' not found in presentation")
            return False
        
        # Get position from transform
        transform = shape_info['transform']
        translate_x = transform.get('translateX', 0)
        translate_y = transform.get('translateY', 0)
        
        # Get size - use specified dimensions or fall back to original shape size
        original_size = shape_info['size']
        if width_inches is not None:
            width_emu = int(width_inches * EMU_PER_INCH)
        else:
            width_emu = original_size.get('width', {}).get('magnitude', 6000000)
        
        if height_inches is not None:
            height_emu = int(height_inches * EMU_PER_INCH)
        else:
            height_emu = original_size.get('height', {}).get('magnitude', 2000000)
        
        # Generate unique table ID
        table_id = f"table_{uuid.uuid4().hex[:8]}"
        
        rows = len(df) + 1  # +1 for header
        cols = len(df.columns)
        
        # Step 2: Delete placeholder and create table
        requests = [
            # Delete the placeholder shape
            {
                'deleteObject': {
                    'objectId': shape_info['object_id']
                }
            },
            # Create the table at the placeholder's position
            {
                'createTable': {
                    'objectId': table_id,
                    'elementProperties': {
                        'pageObjectId': shape_info['slide_id'],
                        'size': {
                            'height': {'magnitude': height_emu, 'unit': 'EMU'},
                            'width': {'magnitude': width_emu, 'unit': 'EMU'}
                        },
                        'transform': {
                            'scaleX': 1,
                            'scaleY': 1,
                            'translateX': translate_x,
                            'translateY': translate_y,
                            'unit': 'EMU'
                        }
                    },
                    'rows': rows,
                    'columns': cols
                }
            }
        ]
        
        try:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
        except Exception as e:
            print(f"Error creating table: {e}")
            return False
        
        # Step 3: Populate table with data and apply styling
        requests = []
        
        # Add header row text
        for col_idx, col_name in enumerate(df.columns):
            requests.append({
                'insertText': {
                    'objectId': table_id,
                    'cellLocation': {
                        'rowIndex': 0,
                        'columnIndex': col_idx
                    },
                    'text': str(col_name),
                    'insertionIndex': 0
                }
            })
        
        # Add data rows
        for row_idx, row in enumerate(df.itertuples(index=False), start=1):
            for col_idx, value in enumerate(row):
                requests.append({
                    'insertText': {
                        'objectId': table_id,
                        'cellLocation': {
                            'rowIndex': row_idx,
                            'columnIndex': col_idx
                        },
                        'text': str(value) if value is not None else '',
                        'insertionIndex': 0
                    }
                })
        
        # Define colors
        if header_bg_color is None:
            header_bg_color = {'red': 0.18, 'green': 0.32, 'blue': 0.45}  # Dark blue like in image
        
        alt_row_color = {'red': 0.95, 'green': 0.95, 'blue': 0.95}  # Light gray for alternating rows
        white_color = {'red': 1.0, 'green': 1.0, 'blue': 1.0}
        dark_text_color = {'red': 0.2, 'green': 0.2, 'blue': 0.2}  # Dark gray text
        
        # Style header row - background and cell properties
        for col_idx in range(cols):
            requests.append({
                'updateTableCellProperties': {
                    'objectId': table_id,
                    'tableRange': {
                        'location': {'rowIndex': 0, 'columnIndex': col_idx},
                        'rowSpan': 1,
                        'columnSpan': 1
                    },
                    'tableCellProperties': {
                        'tableCellBackgroundFill': {
                            'solidFill': {
                                'color': {'rgbColor': header_bg_color}
                            }
                        },
                        'contentAlignment': 'MIDDLE'
                    },
                    'fields': 'tableCellBackgroundFill,contentAlignment'
                }
            })
        
        # Style header text (white, bold, centered)
        for col_idx in range(cols):
            requests.append({
                'updateTextStyle': {
                    'objectId': table_id,
                    'cellLocation': {
                        'rowIndex': 0,
                        'columnIndex': col_idx
                    },
                    'style': {
                        'foregroundColor': {
                            'opaqueColor': {
                                'rgbColor': white_color
                            }
                        },
                        'bold': True,
                        'fontSize': {'magnitude': font_size, 'unit': 'PT'},
                        'fontFamily': 'Arial'
                    },
                    'textRange': {'type': 'ALL'},
                    'fields': 'foregroundColor,bold,fontSize,fontFamily'
                }
            })
            # Center align header text
            requests.append({
                'updateParagraphStyle': {
                    'objectId': table_id,
                    'cellLocation': {
                        'rowIndex': 0,
                        'columnIndex': col_idx
                    },
                    'style': {
                        'alignment': 'CENTER'
                    },
                    'textRange': {'type': 'ALL'},
                    'fields': 'alignment'
                }
            })
        
        # Style data rows (with or without alternating colors)
        for row_idx in range(1, rows):
            # Use alternating colors only if enabled, otherwise white for all rows
            if alternate_row_colors:
                row_bg_color = alt_row_color if row_idx % 2 == 0 else white_color
            else:
                row_bg_color = white_color
            
            for col_idx in range(cols):
                # Set cell background
                requests.append({
                    'updateTableCellProperties': {
                        'objectId': table_id,
                        'tableRange': {
                            'location': {'rowIndex': row_idx, 'columnIndex': col_idx},
                            'rowSpan': 1,
                            'columnSpan': 1
                        },
                        'tableCellProperties': {
                            'tableCellBackgroundFill': {
                                'solidFill': {
                                    'color': {'rgbColor': row_bg_color}
                                }
                            },
                            'contentAlignment': 'MIDDLE'
                        },
                        'fields': 'tableCellBackgroundFill,contentAlignment'
                    }
                })
                
                # Style text
                requests.append({
                    'updateTextStyle': {
                        'objectId': table_id,
                        'cellLocation': {
                            'rowIndex': row_idx,
                            'columnIndex': col_idx
                        },
                        'style': {
                            'foregroundColor': {
                                'opaqueColor': {
                                    'rgbColor': dark_text_color
                                }
                            },
                            'fontSize': {'magnitude': font_size, 'unit': 'PT'},
                            'fontFamily': 'Arial'
                        },
                        'textRange': {'type': 'ALL'},
                        'fields': 'foregroundColor,fontSize,fontFamily'
                    }
                })
                
                # Center align data (numbers look better centered)
                requests.append({
                    'updateParagraphStyle': {
                        'objectId': table_id,
                        'cellLocation': {
                            'rowIndex': row_idx,
                            'columnIndex': col_idx
                        },
                        'style': {
                            'alignment': 'CENTER'
                        },
                        'textRange': {'type': 'ALL'},
                        'fields': 'alignment'
                    }
                })
        
        try:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': requests}
            ).execute()
            return True
        except Exception as e:
            print(f"Error populating table: {e}")
            return False
    
    def delete_placeholder_shape(self, presentation_id: str, placeholder_text: str) -> bool:
        """
        Finds and deletes a placeholder shape by its text content.
        Useful for removing unused placeholders from templates.
        
        Args:
            presentation_id: ID of the presentation
            placeholder_text: Text in the shape to find and delete (e.g., "{{monthly_data_transfer}}")
            
        Returns:
            True if deletion was successful, False otherwise
        """
        # Find the placeholder shape
        element_info = self.get_element_by_text(presentation_id, placeholder_text)
        
        if not element_info:
            print(f"Placeholder shape '{placeholder_text}' not found - nothing to delete.")
            return False
        
        # Delete the element
        try:
            self.delete_element(presentation_id, element_info['object_id'])
            print(f"Successfully deleted placeholder '{placeholder_text}'")
            return True
        except Exception as e:
            print(f"Error deleting placeholder '{placeholder_text}': {e}")
            return False
    
    def get_all_elements_by_text(self, presentation_id: str, search_text: str) -> list:
        """
        Finds ALL page elements (shapes) containing the specified text.
        
        Args:
            presentation_id: ID of the presentation
            search_text: Text to search for in shape content
            
        Returns:
            List of dictionaries with element details (object_id, slide_id, size, transform, text)
        """
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        elements_found = []
        
        for slide in presentation.get('slides', []):
            slide_id = slide.get('objectId')
            for element in slide.get('pageElements', []):
                if 'shape' in element:
                    shape = element['shape']
                    text_content = ''
                    if 'text' in shape:
                        for te in shape.get('text', {}).get('textElements', []):
                            if 'textRun' in te:
                                text_content += te['textRun'].get('content', '')
                    
                    if search_text in text_content:
                        transform = element.get('transform', {})
                        elements_found.append({
                            'object_id': element['objectId'],
                            'slide_id': slide_id,
                            'size': element.get('size', {}),
                            'transform': transform,
                            'text': text_content.strip(),
                            'x_position': transform.get('translateX', 0)
                        })
        
        return elements_found
    
    def update_element_x_position(self, presentation_id: str, element_text: str, x_emu: float, 
                                   min_current_x: float = None, max_current_x: float = None) -> bool:
        """
        Updates the X position of an element found by its text content.
        Optionally filter by current X position range to distinguish duplicates.
        
        Args:
            presentation_id: ID of the presentation
            element_text: Text content to search for
            x_emu: New X position in EMU (English Metric Units)
            min_current_x: Optional minimum current X position to filter by (in EMU)
            max_current_x: Optional maximum current X position to filter by (in EMU)
            
        Returns:
            True if update was successful, False otherwise
        """
        # If position filter is provided, use get_all_elements_by_text and filter
        if min_current_x is not None or max_current_x is not None:
            all_elements = self.get_all_elements_by_text(presentation_id, element_text)
            element = None
            for el in all_elements:
                current_x = el.get('x_position', 0)
                if min_current_x is not None and current_x < min_current_x:
                    continue
                if max_current_x is not None and current_x > max_current_x:
                    continue
                element = el
                break
        else:
            element = self.get_element_by_text(presentation_id, element_text)
        
        if not element:
            return False
        
        transform = element.get('transform', {})
        
        # Update only the X position, keep everything else
        request = {
            'updatePageElementTransform': {
                'objectId': element['object_id'],
                'transform': {
                    'scaleX': transform.get('scaleX', 1),
                    'scaleY': transform.get('scaleY', 1),
                    'shearX': transform.get('shearX', 0),
                    'shearY': transform.get('shearY', 0),
                    'translateX': x_emu,
                    'translateY': transform.get('translateY', 0),
                    'unit': 'EMU'
                },
                'applyMode': 'ABSOLUTE'
            }
        }
        
        try:
            self.slides_service.presentations().batchUpdate(
                presentationId=presentation_id,
                body={'requests': [request]}
            ).execute()
            return True
        except Exception as e:
            print(f"Error updating position for '{element_text}': {e}")
            return False
    
    def redistribute_horizontal_elements(self, presentation_id: str, placeholders: list, 
                                          deleted_placeholder: str) -> bool:
        """
        Redistributes horizontal space among remaining elements after one is deleted.
        This method finds the remaining placeholders and expands them to fill the space
        that was occupied by the deleted element.
        
        Args:
            presentation_id: ID of the presentation
            placeholders: List of placeholder texts that should be redistributed
            deleted_placeholder: Text of the placeholder that was deleted
            
        Returns:
            True if redistribution was successful, False otherwise
        """
        try:
            # Find all remaining placeholder elements and their positions
            elements_info = []
            for placeholder in placeholders:
                element = self.get_element_by_text(presentation_id, placeholder)
                if element:
                    elements_info.append({
                        'object_id': element['object_id'],
                        'slide_id': element['slide_id'],
                        'transform': element['transform'],
                        'size': element['size'],
                        'text': placeholder
                    })
            
            if len(elements_info) < 2:
                print(f"Not enough elements found for redistribution (found {len(elements_info)})")
                return False
            
            # Sort elements by their X position (left to right)
            elements_info.sort(key=lambda e: e['transform'].get('translateX', 0))
            
            # Calculate the total available width
            # Assume all elements are on the same row and we want to distribute evenly
            first_x = elements_info[0]['transform'].get('translateX', 0)
            last_element = elements_info[-1]
            last_x = last_element['transform'].get('translateX', 0)
            last_width = last_element['size'].get('width', {}).get('magnitude', 0)
            
            # Total width = from first element's left edge to last element's right edge
            # For 2 elements filling 3 slots, each element should be ~1.5x wider
            original_width = elements_info[0]['size'].get('width', {}).get('magnitude', 0)
            
            # Calculate new width: increase by 50% when going from 3 to 2 elements
            new_width = int(original_width * 1.5)
            
            # Calculate spacing between elements
            if len(elements_info) == 2:
                # For 2 elements, calculate the gap between them
                total_available = last_x + last_width - first_x
                gap = (total_available - (new_width * 2)) // 1  # Space between the 2 elements
                if gap < 0:
                    gap = original_width * 0.1  # Default 10% gap
            
            # Update each element's size and position
            requests = []
            for i, element in enumerate(elements_info):
                # Calculate new X position: spread elements evenly
                new_x = first_x + (i * (new_width + gap)) if len(elements_info) == 2 else element['transform'].get('translateX', 0)
                
                # Update size
                requests.append({
                    'updatePageElementTransform': {
                        'objectId': element['object_id'],
                        'transform': {
                            'scaleX': new_width / original_width if original_width > 0 else 1,
                            'scaleY': element['transform'].get('scaleY', 1),
                            'shearX': element['transform'].get('shearX', 0),
                            'shearY': element['transform'].get('shearY', 0),
                            'translateX': new_x,
                            'translateY': element['transform'].get('translateY', 0),
                            'unit': 'EMU'
                        },
                        'applyMode': 'ABSOLUTE'
                    }
                })
            
            if requests:
                self.slides_service.presentations().batchUpdate(
                    presentationId=presentation_id,
                    body={'requests': requests}
                ).execute()
                print(f"Successfully redistributed {len(elements_info)} elements")
                return True
            
            return False
            
        except Exception as e:
            print(f"Error redistributing elements: {e}")
            return False
    
    def get_presentation_structure(self, presentation_id: str) -> list:
        """
        Get the structure of a presentation including all slides and their elements.
        Useful for understanding template structure and finding placeholder locations.
        
        Args:
            presentation_id: ID of the presentation
            
        Returns:
            List of slide information dictionaries
        """
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        slides_info = []
        
        for slide_index, slide in enumerate(presentation.get('slides', []), 1):
            slide_info = {
                'slide_number': slide_index,
                'slide_id': slide.get('objectId'),
                'layout': slide.get('slideProperties', {}).get('layoutObjectId'),
                'elements': []
            }
            
            for element in slide.get('pageElements', []):
                element_info = {
                    'object_id': element.get('objectId'),
                    'type': self._get_element_type(element)
                }
                
                # Extract text content if available
                if 'shape' in element:
                    shape = element['shape']
                    if 'text' in shape:
                        text_content = self._extract_text_from_element(shape['text'])
                        if text_content:
                            element_info['text'] = text_content[:100]  # First 100 chars
                
                # Check for tables
                if 'table' in element:
                    element_info['rows'] = element['table'].get('rows', 0)
                    element_info['columns'] = element['table'].get('columns', 0)
                
                # Check for images
                if 'image' in element:
                    element_info['content_url'] = element['image'].get('contentUrl', 'N/A')
                
                # Check for charts
                if 'sheetsChart' in element:
                    element_info['spreadsheet_id'] = element['sheetsChart'].get('spreadsheetId')
                    element_info['chart_id'] = element['sheetsChart'].get('chartId')
                
                slide_info['elements'].append(element_info)
            
            slides_info.append(slide_info)
        
        return slides_info
    
    def _get_element_type(self, element: dict) -> str:
        """Helper to determine element type"""
        if 'shape' in element:
            return f"shape:{element['shape'].get('shapeType', 'unknown')}"
        if 'table' in element:
            return 'table'
        if 'image' in element:
            return 'image'
        if 'sheetsChart' in element:
            return 'sheets_chart'
        if 'line' in element:
            return 'line'
        if 'video' in element:
            return 'video'
        return 'unknown'
    
    def _extract_text_from_element(self, text_elements: dict) -> str:
        """Helper to extract text content from shape"""
        text_parts = []
        for text_element in text_elements.get('textElements', []):
            if 'textRun' in text_element:
                text_parts.append(text_element['textRun'].get('content', ''))
        return ''.join(text_parts).strip()
    
    def add_linked_chart_to_slide(self, presentation_id: str, slide_id: str,
                                   spreadsheet_id: str, chart_id: int,
                                   x_inches: float, y_inches: float,
                                   width_inches: float, height_inches: float,
                                   object_id: str = None) -> str:
        """
        Add a linked chart to a specific slide at a specific position.
        
        Args:
            presentation_id: ID of the presentation
            slide_id: ID of the slide (use get_presentation_structure to find)
            spreadsheet_id: ID of the Google Sheets spreadsheet
            chart_id: ID of the chart in the spreadsheet
            x_inches: X position in inches from left
            y_inches: Y position in inches from top
            width_inches: Chart width in inches
            height_inches: Chart height in inches
            object_id: Optional custom object ID for the chart
            
        Returns:
            Object ID of the created chart
        """
        import uuid
        
        if object_id is None:
            object_id = f"chart_{uuid.uuid4().hex[:8]}"
        
        # Convert inches to EMU (1 inch = 914400 EMU)
        EMU_PER_INCH = 914400
        
        request = {
            'createSheetsChart': {
                'objectId': object_id,
                'spreadsheetId': spreadsheet_id,
                'chartId': chart_id,
                'linkingMode': 'LINKED',
                'elementProperties': {
                    'pageObjectId': slide_id,
                    'size': {
                        'height': {'magnitude': int(height_inches * EMU_PER_INCH), 'unit': 'EMU'},
                        'width': {'magnitude': int(width_inches * EMU_PER_INCH), 'unit': 'EMU'}
                    },
                    'transform': {
                        'scaleX': 1,
                        'scaleY': 1,
                        'translateX': int(x_inches * EMU_PER_INCH),
                        'translateY': int(y_inches * EMU_PER_INCH),
                        'unit': 'EMU'
                    }
                }
            }
        }
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': [request]}
        ).execute()
        
        return object_id
    
    def get_slide_by_index(self, presentation_id: str, slide_index: int) -> str:
        """
        Get slide ID by its index (1-based).
        
        Args:
            presentation_id: ID of the presentation
            slide_index: 1-based index of the slide
            
        Returns:
            Slide object ID
        """
        presentation = self.slides_service.presentations().get(
            presentationId=presentation_id
        ).execute()
        
        slides = presentation.get('slides', [])
        if 0 < slide_index <= len(slides):
            return slides[slide_index - 1].get('objectId')
        
        raise ValueError(f"Slide index {slide_index} out of range. Presentation has {len(slides)} slides.")
    
    def delete_element(self, presentation_id: str, object_id: str) -> bool:
        """
        Delete an element from the presentation by its object ID.
        
        Args:
            presentation_id: ID of the presentation
            object_id: ID of the element to delete
            
        Returns:
            True if successful
        """
        request = {
            'deleteObject': {
                'objectId': object_id
            }
        }
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': [request]}
        ).execute()
        
        return True
    
    def update_text_in_shape(self, presentation_id: str, shape_object_id: str, 
                             new_text: str, preserve_style: bool = True) -> bool:
        """
        Update text in a specific shape while optionally preserving formatting.
        
        Args:
            presentation_id: ID of the presentation
            shape_object_id: Object ID of the shape to update
            new_text: New text content
            preserve_style: If True, attempts to preserve existing text style
            
        Returns:
            True if successful
        """
        requests = [
            # First, delete all text in the shape
            {
                'deleteText': {
                    'objectId': shape_object_id,
                    'textRange': {
                        'type': 'ALL'
                    }
                }
            },
            # Then insert new text
            {
                'insertText': {
                    'objectId': shape_object_id,
                    'text': new_text,
                    'insertionIndex': 0
                }
            }
        ]
        
        self.slides_service.presentations().batchUpdate(
            presentationId=presentation_id,
            body={'requests': requests}
        ).execute()
        
        return True
    
    def populate_template(self, template_id: str, new_name: str,
                          text_replacements: Dict[str, str] = None,
                          chart_replacements: Dict[str, tuple] = None,
                          folder_id: str = None) -> Dict[str, Any]:
        """
        Complete workflow to create a presentation from a template with data.
        
        This is the main method for template-based presentation creation.
        
        Args:
            template_id: ID of the template presentation
            new_name: Name for the new presentation
            text_replacements: Dict mapping placeholder text to values
                              e.g., {'{{CUSTOMER_NAME}}': 'Acme Corp'}
            chart_replacements: Dict mapping placeholder text to (spreadsheet_id, chart_id) tuples
                               e.g., {'{{CONSUMPTION_CHART}}': ('sheet_id', 12345)}
            folder_id: Optional folder ID
            
        Returns:
            Dictionary with presentation_id, url, and statistics
        """
        # Step 1: Copy the template
        result = self.copy_template(template_id, new_name, folder_id)
        presentation_id = result['presentation_id']
        
        stats = {
            'text_replacements': 0,
            'chart_replacements': 0
        }
        
        # Step 2: Replace text placeholders
        if text_replacements:
            stats['text_replacements'] = self.replace_text_placeholders(
                presentation_id, text_replacements
            )
        
        # Step 3: Replace shape placeholders with charts
        if chart_replacements:
            for placeholder, (spreadsheet_id, chart_id) in chart_replacements.items():
                if self.replace_shape_with_linked_chart(
                    presentation_id, placeholder, spreadsheet_id, chart_id
                ):
                    stats['chart_replacements'] += 1
        
        result['stats'] = stats
        return result