import requests

url = "https://api.picgallery.in/api/v1/public/share-links/tfLivV4safI/face-search"
files = {'file': ('test.jpg', b'dummy content', 'image/jpeg')}
try:
    response = requests.post(url, files=files)
    print("Status:", response.status_code)
    print("Headers:", response.headers)
    print("Text:", response.text)
except Exception as e:
    print("Error:", e)
