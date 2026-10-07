with open('app/schemas/gallery.py', 'a', encoding='utf-8') as f:
    f.write('''

from enum import Enum
class DeleteMode(str, Enum):
    move_up = "move_up"
    delete_all = "delete_all"

class DeletePreviewResponse(BaseModel):
    mode: DeleteMode
    folders_affected: int
    albums_affected: int
    media_affected: int
''')
