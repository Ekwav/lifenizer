import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { map, catchError } from 'rxjs/operators';
import { SearchFieldResult } from 'ngx-mat-search-field';

@Injectable({
  providedIn: 'root'
})
export class ConversationService {

  constructor(private http: HttpClient) { }

  getConversations(search: string, size: number, skip: number): import("rxjs").Observable<import("ngx-mat-search-field").SearchFieldResult> {
    const page = Math.round(skip / size) + 1;
    return this.http
      .get(`https://localhost:5001/api/search/${search.toLowerCase()}?page=${page}`)
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
            items: data.items.map((item: any) => {
              return {
                title: `${item.originalUrl}|${item.importedUrl}`,
                value: item.createdDate
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
  }

}
