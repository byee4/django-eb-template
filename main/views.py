from django.db import connection
from django.http import JsonResponse
from django.shortcuts import render


def healthz(request):
    with connection.cursor() as cursor:
        cursor.execute("SELECT 1")
        cursor.fetchone()
    return JsonResponse({"ok": True})


def home(request):
    return render(request, "main/index.html")
