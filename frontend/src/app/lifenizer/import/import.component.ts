import { Component } from '@angular/core';
import { HttpClient, HttpHeaders } from '@angular/common/http';

interface UploadFile {
  id: string;
  name: string;
  size: number;
  progress: number;
  status: 'pending' | 'uploading' | 'done' | 'error';
  error?: string;
}

@Component({
  selector: 'app-import',
  templateUrl: './import.component.html',
  styleUrls: ['import.component.scss'],
  standalone: false
})
export class ImportComponent {

  url = 'http://localhost:5000/api/upload/';
  token = "my nice token";
  files: UploadFile[] = [];
  dragOver: boolean = false;
  converter: string = "png";
  maxFileSize = 1000000000;

  constructor(private http: HttpClient) {}

  onFilesAdded(files: File[]): void {
    for (const file of files) {
      if (file.size > this.maxFileSize) {
        console.error(`File ${file.name} exceeds max size`);
        continue;
      }

      const uploadFile: UploadFile = {
        id: Math.random().toString(36).substr(2, 9),
        name: file.name,
        size: file.size,
        progress: 0,
        status: 'pending'
      };

      this.files.push(uploadFile);
      this.uploadFile(uploadFile, file);
    }
  }

  private uploadFile(uploadFile: UploadFile, file: File): void {
    uploadFile.status = 'uploading';

    const formData = new FormData();
    formData.append('file', file);

    const headers = new HttpHeaders({
      'Authorization': `bearer ${this.token}`,
      'Kevin': 'no'
    });

    this.http.post<any>(`${this.url}${this.converter}`, formData, {
      headers: headers,
      reportProgress: true,
      observe: 'events'
    }).subscribe(
      (event: any) => {
        if (event.type === 1) { // ProgressEvent
          uploadFile.progress = Math.round((event.loaded / event.total) * 100);
        } else if (event.type === 4) { // HttpResponse
          uploadFile.status = 'done';
          uploadFile.progress = 100;
        }
      },
      (error) => {
        uploadFile.status = 'error';
        uploadFile.error = error.message || 'Upload failed';
      }
    );
  }

  cancelUpload(id: string): void {
    const file = this.files.find(f => f.id === id);
    if (file) {
      file.status = 'pending';
      // In a real app, you'd abort the request here
    }
  }

  removeFile(id: string): void {
    this.files = this.files.filter(file => file.id !== id);
  }

  removeAllFiles(): void {
    this.files = [];
  }

  humanizeBytes(bytes: number): string {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + ' ' + sizes[i];
  }
}
