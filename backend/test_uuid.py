import uuid
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

engine = create_engine("postgresql+psycopg://postgres:postgres@localhost:5432/picgallery")
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

db = SessionLocal()
folder_id = uuid.uuid4()
try:
    descendant_folders = db.execute(
        text("""
            WITH RECURSIVE folder_tree AS (
                SELECT id FROM folders WHERE id = :root_id
                UNION
                SELECT f.id FROM folders f
                INNER JOIN folder_tree ft ON f.parent_id = ft.id
            )
            SELECT id FROM folder_tree
        """),
        {"root_id": folder_id}
    ).scalars().all()
    print("SUCCESS uuid obj")
except Exception as e:
    print(f"ERROR uuid obj: {e}")

try:
    descendant_folders = db.execute(
        text("""
            WITH RECURSIVE folder_tree AS (
                SELECT id FROM folders WHERE id = :root_id
                UNION
                SELECT f.id FROM folders f
                INNER JOIN folder_tree ft ON f.parent_id = ft.id
            )
            SELECT id FROM folder_tree
        """),
        {"root_id": str(folder_id)}
    ).scalars().all()
    print("SUCCESS str obj")
except Exception as e:
    print(f"ERROR str obj: {e}")
