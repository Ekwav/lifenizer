import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { map, catchError } from 'rxjs/operators';
import Fuse from 'fuse.js';


export interface Conversation {
  originalUrl: string;
  importedUrl: string;
  createdDate: Date;
  consumedDate: Date;
  participants: string[];
  sourceType: string;
  keywords: string[];
  metaText: string;
  dataPoints: DataPoint[];
}

export interface DataPoint {
  offset: number;
  content: string;
}