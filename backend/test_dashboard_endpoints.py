import sys
import os

# Add backend directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))

from app.db.session import SessionLocal
from app.models.user import User
from app.api.routes.admin_dashboard import get_admin_dashboard_stats, get_client_stats, get_analytics
from app.api.routes.connections import list_connections
from app.api.routes.media import list_media
from app.api.routes.notifications import list_notifications
from app.api.routes.activity_log import list_activity_log
from app.api.routes.albums import list_albums

def test_endpoints():
    db = SessionLocal()
    try:
        user = db.query(User).first()
        if not user:
            print("No users found.")
            return

        print(f"Testing for user: {user.id}")

        print("\n--- /admin-dashboard/stats ---")
        try:
            res = get_admin_dashboard_stats(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /connections ---")
        try:
            res = list_connections(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /media ---")
        try:
            res = list_media(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /notifications ---")
        try:
            res = list_notifications(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /activity-log ---")
        try:
            res = list_activity_log(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /admin-dashboard/analytics ---")
        try:
            res = get_analytics(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /albums ---")
        try:
            res = list_albums(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

        print("\n--- /admin-dashboard/client-stats ---")
        try:
            res = get_client_stats(current_user=user, db=db)
            print("SUCCESS")
        except Exception as e:
            print(f"FAILED: {type(e).__name__} - {e}")

    finally:
        db.close()

if __name__ == "__main__":
    test_endpoints()
