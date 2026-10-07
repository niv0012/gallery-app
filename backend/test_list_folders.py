import uuid
from app.db.session import SessionLocal
from app.api.routes.folders import list_folders, _folder_counts, _get_active_share_folder_ids
from app.models.user import User

db = SessionLocal()
user = db.query(User).filter(User.id == "81a32cde-f241-4bbe-b34d-3f8346098ade").first()
if not user:
    print("No user")
    exit(1)

print(f"Testing list_folders for {user.id}")
try:
    res = list_folders(current_user=user, db=db)
    print(f"Got {len(res)} folders")
except Exception as e:
    import traceback
    traceback.print_exc()
