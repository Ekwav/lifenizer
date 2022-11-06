import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { map, catchError } from 'rxjs/operators';
import Fuse from 'fuse.js';

@Injectable({
  providedIn: 'root'
})
export class ConversationService {

  constructor(private http: HttpClient) { }
/*
  getConversations(search: string, size: number, skip: number): import("rxjs").Observable<import("ngx-mat-search-field").SearchFieldResult> {
    const page = Math.round(skip / size) + 1;
    return this.http
      .get(`http://localhost:5000/api/search/${search.toLowerCase()}?page=${page}`)
      .pipe(
        map((data: any) => {
          let count = 1;
          if (page === 1 && data.info && data.pageCount) {
            count = Number(data.total);
          }
          return {
            info: {
              count: count
            },
            items: data.items.map((item: Conversation) => {
              var fuse = new Fuse(item.dataPoints,{keys:['content']});
              var points = fuse.search(search);
              var match = points[0].item.content
              console.log(match);
              return {
                title: match,//`${item.originalUrl}|${item.importedUrl}`,
                value: 'onlineUrl-'+item.importedUrl
              };
            })
          };
        }),
        catchError((err: any) => {
          return of({
            info: {
              count: 0
            },
            items: []
          });
        })
      );
  }*/

}
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